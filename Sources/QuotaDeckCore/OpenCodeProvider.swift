import Foundation

public struct OpenCodeProvider: QuotaProvider, Sendable {
    public let id: ProviderID = .openCode
    public let displayName: String = "OpenCode Go"
    public let capabilities: ProviderCapabilities = [.quotaWindows, .subscriptionCycle]

    public static let serviceName = "com.quotadeck.opencode-go"

    private let credentialStore: CredentialStore
    private let baseURL: URL
    private let session: URLSession

    public init(
        credentialStore: CredentialStore = KeychainCredentialStore.shared,
        baseURL: URL = URL(string: "https://opencode.ai/zen/go/v1")!,
        session: URLSession = .shared
    ) {
        self.credentialStore = credentialStore
        self.baseURL = baseURL
        self.session = session
    }

    public func fetchSubscription(account: AccountProfile) async throws -> SubscriptionInfo {
        let apiKey = credentialStore.load(service: Self.serviceName, account: account.id) ?? Self.resolveLocalKey()
        guard let key = apiKey, !key.isEmpty else {
            return SubscriptionInfo(
                tierName: "Key Missing",
                tier: .free,
                status: .paymentRequired,
                quotaWindows: []
            )
        }

        let endpoint = baseURL.appendingPathComponent("usage")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaDeck", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            if httpResponse.statusCode == 403 {
                return SubscriptionInfo(
                    tierName: "No Subscription",
                    tier: .free,
                    status: .expired,
                    quotaWindows: []
                )
            }
            if httpResponse.statusCode == 401 {
                return SubscriptionInfo(
                    tierName: "OpenCode Go",
                    tier: .pro,
                    status: .paymentRequired,
                    quotaWindows: []
                )
            }
            guard (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return SubscriptionInfo(
                    tierName: "OpenCode Go",
                    tier: .pro,
                    status: .unknown,
                    quotaWindows: []
                )
            }

            return Self.parseSubscription(from: json)
        } catch {
            return SubscriptionInfo(
                tierName: "OpenCode Go",
                tier: .pro,
                status: .unknown,
                quotaWindows: []
            )
        }
    }

    public func switchActiveProfile(to accountID: String) async throws {
        // Multi-account profile switching
    }

    public static func parseSubscription(from json: [String: Any]) -> SubscriptionInfo {
        guard let usage = json["usage"] as? [String: Any] else {
            return SubscriptionInfo(
                tierName: "OpenCode Go",
                tier: .pro,
                status: .unknown,
                quotaWindows: []
            )
        }

        var windows: [QuotaWindow] = []

        if let rolling = usage["rolling"] as? [String: Any],
           let used = parsePercent(rolling["percent"]) {
            windows.append(QuotaWindow(
                label: "5-Hour Window",
                usedPercent: used,
                resetsAt: (rolling["resetsAt"] as? String).flatMap(parseISO8601Date)
            ))
        }

        if let weekly = usage["weekly"] as? [String: Any],
           let used = parsePercent(weekly["percent"]) {
            windows.append(QuotaWindow(
                label: "Weekly Quota",
                usedPercent: used,
                resetsAt: (weekly["resetsAt"] as? String).flatMap(parseISO8601Date)
            ))
        }

        if let monthly = usage["monthly"] as? [String: Any],
           let used = parsePercent(monthly["percent"]) {
            windows.append(QuotaWindow(
                label: "Monthly Limit",
                usedPercent: used,
                resetsAt: (monthly["resetsAt"] as? String).flatMap(parseISO8601Date)
            ))
        }

        let isExhausted = windows.contains { $0.usedPercent >= 100.0 }

        return SubscriptionInfo(
            tierName: "OpenCode Go Pro",
            tier: .pro,
            status: isExhausted ? .quotaExhausted : .active,
            quotaWindows: windows
        )
    }

    private static func resolveLocalKey() -> String? {
        // Look up ~/.opencode/auth.json
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".opencode/auth.json")
        if let data = try? Data(contentsOf: authURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let goDict = json["opencode-go"] as? [String: Any], let key = goDict["key"] as? String {
                return key
            }
            if let key = json["key"] as? String {
                return key
            }
        }
        return nil
    }

    private static func parsePercent(_ value: Any?) -> Double? {
        if let num = value as? NSNumber { return num.doubleValue }
        if let str = value as? String {
            return Double(str.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func parseISO8601Date(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)
    }
}
