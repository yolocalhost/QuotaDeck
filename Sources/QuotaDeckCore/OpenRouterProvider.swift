import Foundation

public struct OpenRouterProvider: QuotaProvider, Sendable {
    public let id: ProviderID = .openRouter
    public let displayName: String = "OpenRouter"
    public let capabilities: ProviderCapabilities = [.creditBalance, .quotaWindows]

    public static let serviceName = "com.quotadeck.openrouter"

    private let credentialStore: CredentialStore
    private let session: URLSession
    private let baseURL: URL

    public init(
        credentialStore: CredentialStore = KeychainCredentialStore.shared,
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        session: URLSession = .shared
    ) {
        self.credentialStore = credentialStore
        self.baseURL = baseURL
        self.session = session
    }

    public func fetchSubscription(account: AccountProfile) async throws -> SubscriptionInfo {
        guard let apiKey = credentialStore.load(service: Self.serviceName, account: account.id), !apiKey.isEmpty else {
            return SubscriptionInfo(
                tierName: "API Key Missing",
                tier: .payAsYouGo,
                status: .paymentRequired,
                quotaWindows: []
            )
        }

        // Fetch /credits and /auth/key
        var creditsBalance: Decimal?
        var windows: [QuotaWindow] = []
        var tierStatus: SubscriptionInfo.Status = .active

        if let creditsJSON = try? await requestJSON(path: "/credits", apiKey: apiKey),
           let data = creditsJSON["data"] as? [String: Any],
           let totalCredits = data["total_credits"] as? Double,
           let totalUsage = data["total_usage"] as? Double {
            let balance = max(0.0, totalCredits - totalUsage)
            creditsBalance = Decimal(balance)
            if balance <= 0 {
                tierStatus = .quotaExhausted
            }
        }

        if let keyJSON = try? await requestJSON(path: "/auth/key", apiKey: apiKey),
           let data = keyJSON["data"] as? [String: Any] {
            if let limit = data["limit"] as? Double, limit > 0,
               let usage = data["usage"] as? Double {
                let usedPct = min(100.0, (usage / limit) * 100.0)
                windows.append(QuotaWindow(
                    label: "Monthly Limit",
                    usedPercent: usedPct,
                    remainingUnits: String(format: "$%.2f / $%.2f", max(0.0, limit - usage), limit)
                ))
            }

            if let rateLimit = data["rate_limit"] as? [String: Any],
               let interval = rateLimit["interval"] as? String {
                let requests = (rateLimit["requests"] as? NSNumber)?.intValue ?? -1
                if requests > 0 {
                    windows.append(QuotaWindow(
                        label: "Rate Limit (\(interval))",
                        usedPercent: 0.0,
                        remainingUnits: "\(requests) req/\(interval)"
                    ))
                }
            }
        }

        return SubscriptionInfo(
            tierName: "Pay-As-You-Go",
            tier: .payAsYouGo,
            status: tierStatus,
            creditsBalanceUSD: creditsBalance,
            quotaWindows: windows
        )
    }

    public func switchActiveProfile(to accountID: String) async throws {
        // OpenRouter uses API keys per account profile
    }

    private func requestJSON(path: String, apiKey: String) async throws -> [String: Any]? {
        let endpoint = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaDeck", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
