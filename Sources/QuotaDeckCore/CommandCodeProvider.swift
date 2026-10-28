import Foundation

public struct CommandCodeProvider: QuotaProvider, Sendable {
    public let id: ProviderID = .claudeCode
    public let displayName: String = "Command Code"
    public let capabilities: ProviderCapabilities = [.quotaWindows, .subscriptionCycle]

    public static let serviceName = "com.quotadeck.commandcode"
    public static let defaultBaseURL = URL(string: "https://api.commandcode.ai")!

    private let credentialStore: CredentialStore
    private let baseURL: URL
    private let session: URLSession

    public init(
        credentialStore: CredentialStore = KeychainCredentialStore.shared,
        baseURL: URL = CommandCodeProvider.defaultBaseURL,
        session: URLSession = .shared,
        timeout: TimeInterval = 15
    ) {
        self.credentialStore = credentialStore
        self.baseURL = baseURL

        let config = session.configuration
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(
            configuration: config,
            delegate: CommandCodeRedirectRefusingDelegate(),
            delegateQueue: session.delegateQueue
        )
    }

    public func fetchSubscription(account: AccountProfile) async throws -> SubscriptionInfo {
        let apiKey = credentialStore.load(service: Self.serviceName, account: account.id) ?? Self.resolveLocalKey()
        guard let key = apiKey, !key.isEmpty else {
            return SubscriptionInfo(
                tierName: "Not Configured",
                tier: .free,
                status: .paymentRequired,
                quotaWindows: []
            )
        }

        do {
            let whoami = try await requestJSON(
                path: "/alpha/whoami",
                query: [URLQueryItem(name: "limits", value: "1")],
                apiKey: key
            )
            let identity = try Self.identity(from: whoami)
            let scopeQuery = identity.orgID.map { [URLQueryItem(name: "orgId", value: $0)] } ?? []

            let credits = try await requestJSON(
                path: "/alpha/billing/credits",
                query: scopeQuery,
                apiKey: key
            )

            let summary = try? await requestJSON(
                path: "/alpha/usage/summary",
                query: scopeQuery,
                apiKey: key
            )

            return try Self.parseSnapshot(whoami: whoami, credits: credits, summary: summary)
        } catch {
            return SubscriptionInfo(
                tierName: "Command Code",
                tier: .pro,
                status: .unknown,
                quotaWindows: []
            )
        }
    }

    public func switchActiveProfile(to accountID: String) async throws {
        // Multi-profile switching for Command Code
    }

    public static func parseSnapshot(
        whoami: [String: Any],
        credits: [String: Any],
        summary: [String: Any]?,
        planOverride: String? = nil
    ) throws -> SubscriptionInfo {
        var windows: [QuotaWindow] = []

        // Whoami / credits limits
        let limits = (credits["windowLimits"] as? [String: Any]) ?? (whoami["limits"] as? [String: Any]) ?? [:]

        var weeklyCap: Double? = nil

        if let fiveHour = limits["fiveHour"] as? [String: Any],
           let win = window(from: fiveHour) {
            windows.append(QuotaWindow(
                label: "5-Hour Window",
                usedPercent: Double(win.usedPercent),
                resetsAt: win.resetAt
            ))
        }

        if let weekly = limits["weekly"] as? [String: Any],
           let win = window(from: weekly) {
            weeklyCap = number(weekly["cap"])
            windows.append(QuotaWindow(
                label: "Weekly Window",
                usedPercent: Double(win.usedPercent),
                resetsAt: win.resetAt
            ))
        }

        if let monthlyPct = monthlyPercent(credits: credits, summary: summary) {
            windows.append(QuotaWindow(
                label: "Monthly Credits",
                usedPercent: Double(monthlyPct)
            ))
        }

        let isExhausted = windows.contains { $0.usedPercent >= 100.0 }

        let tierName: String
        if let override = planOverride, !override.isEmpty, override != "Auto-Detect" {
            tierName = override
        } else if let wCap = weeklyCap {
            if wCap >= 34.0 && wCap <= 36.0 {
                tierName = "GOAT"
            } else if wCap < 34.0 {
                tierName = "Go"
            } else if wCap <= 100.0 {
                tierName = "Pro"
            } else {
                tierName = "Max"
            }
        } else {
            tierName = "GOAT"
        }

        return SubscriptionInfo(
            tierName: tierName,
            tier: .pro,
            status: isExhausted ? .quotaExhausted : .active,
            quotaWindows: windows
        )
    }

    static func identity(from payload: [String: Any]) throws -> (orgID: String?, accountLabel: String?) {
        let scope = payload["data"] as? [String: Any] ?? payload
        let user = scope["user"] as? [String: Any]
        let orgValue = scope["org"] ?? scope["organization"]

        if let org = orgValue as? [String: Any],
           let orgID = org["id"] as? String,
           !orgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (orgID, accountLabel(from: user))
        }

        return (nil, accountLabel(from: user))
    }

    private static func accountLabel(from user: [String: Any]?) -> String? {
        guard let user else { return nil }
        for key in ["email", "name", "userName"] {
            guard let value = user[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private struct UsageWindow {
        let usedPercent: Int
        let resetAt: Date?
    }

    private static func window(from value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let used = number(dict["used"]),
              let cap = number(dict["cap"]),
              let usedPercent = percent(used: used, cap: cap) else {
            return nil
        }
        let resetAt = number(dict["resetAt"]).flatMap { milliseconds -> Date? in
            guard milliseconds > 0 else { return nil }
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return UsageWindow(usedPercent: usedPercent, resetAt: resetAt)
    }

    private static func monthlyPercent(credits: [String: Any], summary: [String: Any]?) -> Int? {
        guard let summary,
              let spent = number(summary["totalCredits"]) ?? number(summary["totalCost"]),
              let balances = credits["credits"] as? [String: Any] else {
            return nil
        }
        let monthly = number(balances["monthlyCredits"]) ?? 0
        let purchased = number(balances["purchasedCredits"]) ?? 0
        let free = number(balances["freeCredits"]) ?? 0
        return percent(used: spent, cap: monthly + purchased + free + spent)
    }

    private static func percent(used: Double, cap: Double) -> Int? {
        guard used.isFinite, cap.isFinite, cap > 0 else { return nil }
        let fraction = min(max(used / cap, 0), 1)
        return Int((fraction * 100).rounded())
    }

    private static func number(_ value: Any?) -> Double? {
        if let num = value as? NSNumber { return num.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func requestJSON(
        path: String,
        query: [URLQueryItem],
        apiKey: String
    ) async throws -> [String: Any] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + path
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("QuotaDeck", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return json
    }

    public static func resolveLocalKey() -> String? {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".commandcode/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = (json["apiKey"] as? String) ?? (json["key"] as? String) else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class CommandCodeRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
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
