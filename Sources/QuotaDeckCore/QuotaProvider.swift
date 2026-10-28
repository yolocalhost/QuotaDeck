import Foundation

public struct ProviderCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let profileSwitching = ProviderCapabilities(rawValue: 1 << 0)
    public static let quotaWindows = ProviderCapabilities(rawValue: 1 << 1)
    public static let creditBalance = ProviderCapabilities(rawValue: 1 << 2)
    public static let subscriptionCycle = ProviderCapabilities(rawValue: 1 << 3)
}

public protocol QuotaProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }

    func fetchSubscription(account: AccountProfile) async throws -> SubscriptionInfo
    func switchActiveProfile(to accountID: String) async throws
}
