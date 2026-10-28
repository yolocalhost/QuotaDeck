import Foundation
import Security

public struct AntigravityProvider: QuotaProvider, Sendable {
    public let id: ProviderID = .antigravity
    public let displayName: String = "Antigravity"
    public let capabilities: ProviderCapabilities = [.quotaWindows, .subscriptionCycle]

    public static let defaultBaseURL = URL(string: "https://daily-cloudcode-pa.googleapis.com")!
    public static let serviceName = "com.quotadeck.antigravity"

    private static let keychainService = "gemini"
    private static let keychainAccount = "antigravity"
    private static let keychainReadTimeout: TimeInterval = 10
    private static let keychainLock = NSLock()
    private static var cachedKeychainToken: (accessToken: String, expiry: Date?)?

    private let credentialStore: CredentialStore
    private let baseURL: URL
    private let session: URLSession
    private let userAgent: String

    public init(
        credentialStore: CredentialStore = KeychainCredentialStore.shared,
        baseURL: URL = AntigravityProvider.defaultBaseURL,
        session: URLSession = .shared,
        timeout: TimeInterval = 15,
        userAgent: String = AntigravityProvider.installedUserAgent
    ) {
        self.credentialStore = credentialStore
        self.baseURL = baseURL
        self.userAgent = userAgent

        let config = session.configuration
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(
            configuration: config,
            delegate: AntigravityRedirectRefusingDelegate(),
            delegateQueue: session.delegateQueue
        )
    }

    public static var installedUserAgent: String {
        let infoURL = URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Info.plist")
        if let data = try? Data(contentsOf: infoURL),
           let plist = try? PropertyListSerialization.propertyList(
               from: data, options: [], format: nil) as? [String: Any],
           let version = plist["CFBundleShortVersionString"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return "antigravity/\(trimmed)" }
        }
        return "antigravity/2.25.0"
    }

    public func fetchSubscription(account: AccountProfile) async throws -> SubscriptionInfo {
        // 1. Check if user configured a manual token override in Settings
        var token: (accessToken: String, expiry: Date?)? = nil
        if let manualSecret = credentialStore.load(service: Self.serviceName, account: account.id) {
            token = Self.parseTokenSecret(manualSecret)
        }

        // 2. Otherwise auto-discover from system Keychain (where Antigravity saves its token)
        if token == nil {
            token = Self.keychainToken()
        }

        // 3. Fallback: local config file
        if token == nil {
            let tokenURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini/antigravity/auth.json")
            token = try? Self.loadToken(from: tokenURL)
        }

        guard let validToken = token, !validToken.accessToken.isEmpty else {
            return SubscriptionInfo(
                tierName: "Not Configured",
                tier: .free,
                status: .paymentRequired,
                quotaWindows: []
            )
        }

        if let expiry = validToken.expiry, expiry.addingTimeInterval(30) < Date() {
            return SubscriptionInfo(
                tierName: "Antigravity",
                tier: .pro,
                status: .expired,
                quotaWindows: []
            )
        }

        do {
            let payload = try await requestJSON(path: "/v1internal:retrieveUserQuotaSummary", accessToken: validToken.accessToken)
            return Self.parseSubscription(from: payload)
        } catch {
            return SubscriptionInfo(
                tierName: "Antigravity",
                tier: .pro,
                status: .unknown,
                quotaWindows: []
            )
        }
    }

    public func switchActiveProfile(to accountID: String) async throws {
        // Multi-profile switching if multiple Antigravity credentials configured
    }

    public static func parseSubscription(from json: [String: Any]) -> SubscriptionInfo {
        guard let rawGroups = json["groups"] as? [[String: Any]] else {
            return SubscriptionInfo(
                tierName: "Antigravity",
                tier: .pro,
                status: .unknown,
                quotaWindows: []
            )
        }

        var windows: [QuotaWindow] = []

        for group in rawGroups {
            let groupName = (group["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Antigravity"
            let buckets = group["buckets"] as? [[String: Any]] ?? []

            for bucket in buckets {
                if let disabled = bucket["disabled"] as? Bool, disabled { continue }
                guard let remaining = number(bucket["remainingFraction"]) else { continue }

                let rawWindow = (bucket["window"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let bucketID = (bucket["bucketId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resetAt = (bucket["resetTime"] as? String).flatMap(Self.parseDate)

                let fraction = min(max(remaining, 0.0), 1.0)
                let usedPercent = ((1.0 - fraction) * 100.0).rounded()

                let label = Self.formatWindowLabel(groupName: groupName, window: rawWindow.isEmpty ? bucketID : rawWindow)

                windows.append(QuotaWindow(
                    label: label,
                    usedPercent: usedPercent,
                    resetsAt: resetAt
                ))
            }
        }

        let isExhausted = windows.contains { $0.usedPercent >= 100.0 }

        return SubscriptionInfo(
            tierName: "Antigravity Pro",
            tier: .pro,
            status: isExhausted ? .quotaExhausted : .active,
            quotaWindows: windows
        )
    }

    private static func formatWindowLabel(groupName: String, window: String) -> String {
        let win = window.lowercased()
        let winLabel: String
        switch win {
        case "weekly": winLabel = "Weekly"
        case "5h": winLabel = "5-Hour"
        case "daily": winLabel = "Daily"
        default: winLabel = window
        }
        return "\(groupName) (\(winLabel))"
    }

    static func keychainToken() -> (accessToken: String, expiry: Date?)? {
        keychainLock.lock()
        defer { keychainLock.unlock() }

        if let cached = cachedKeychainToken {
            if cached.expiry == nil || cached.expiry! > Date().addingTimeInterval(30) {
                return cached
            }
            cachedKeychainToken = nil
        }

        guard let raw = readKeychainSecret(),
              let token = parseTokenSecret(raw) else {
            return nil
        }
        cachedKeychainToken = token
        return token
    }

    public static func discoverUserEmail() -> String? {
        guard let raw = readKeychainSecret() else { return nil }
        return extractEmailFromSecret(raw)
    }

    public static func extractEmailFromSecret(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let keychainPrefix = "go-keyring-base64:"
        var json: [String: Any]?

        if trimmed.hasPrefix(keychainPrefix) {
            let payload = String(trimmed.dropFirst(keychainPrefix.count))
            if let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) {
                json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        } else if trimmed.hasPrefix("{") {
            json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        }

        guard let dict = json else { return nil }

        if let email = dict["email"] as? String, !email.isEmpty {
            return email
        }

        if let idToken = dict["id_token"] as? String {
            if let email = extractEmailFromJWT(idToken) {
                return email
            }
        }

        return nil
    }

    public static func extractEmailFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = claims["email"] as? String,
              !email.isEmpty else {
            return nil
        }
        return email
    }

    public static func parseTokenSecret(_ raw: String) -> (accessToken: String, expiry: Date?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let keychainPrefix = "go-keyring-base64:"

        if trimmed.hasPrefix(keychainPrefix) {
            let payload = String(trimmed.dropFirst(keychainPrefix.count))
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return token(from: json)
        }
        if trimmed.hasPrefix("{") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
                return nil
            }
            return token(from: json)
        }
        if trimmed.hasPrefix("ya29.") {
            return (trimmed, nil)
        }
        return nil
    }

    private static func token(from json: [String: Any]) -> (accessToken: String, expiry: Date?)? {
        let nested = json["token"] as? [String: Any]
        guard let accessToken = (nested?["access_token"] as? String)
            ?? (json["access_token"] as? String) else {
            return nil
        }
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expiryRaw = (nested?["expiry"] as? String) ?? (json["expiry"] as? String)
        return (trimmed, expiryRaw.flatMap(Self.parseDate))
    }

    private static func loadToken(from tokenFileURL: URL) throws -> (accessToken: String, expiry: Date?) {
        let data = try Data(contentsOf: tokenFileURL)
        guard let raw = String(data: data, encoding: .utf8),
              let token = parseTokenSecret(raw) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return token
    }

    private static func readKeychainSecret() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", keychainService,
            "-a", keychainAccount,
            "-w",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(keychainReadTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func requestJSON(path: String, accessToken: String) async throws -> [String: Any] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + path
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }

    private static func number(_ value: Any?) -> Double? {
        if let num = value as? NSNumber { return num.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

private final class AntigravityRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
