import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case codex = "codex"
    case openCode = "opencode"
    case claudeCode = "claude_code"
    case antigravity = "antigravity"
    case openRouter = "openrouter"

    public var displayName: String {
        switch self {
        case .codex: return "OpenAI Codex"
        case .openCode: return "OpenCode Go"
        case .claudeCode: return "Command Code"
        case .antigravity: return "Antigravity"
        case .openRouter: return "OpenRouter"
        }
    }
}

public struct AccountProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var providerID: ProviderID
    public var label: String
    public var accountEmail: String?
    public var isActive: Bool
    public var customBadgeColor: String?

    public init(
        id: String = UUID().uuidString,
        providerID: ProviderID,
        label: String,
        accountEmail: String? = nil,
        isActive: Bool = false,
        customBadgeColor: String? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.accountEmail = accountEmail
        self.isActive = isActive
        self.customBadgeColor = customBadgeColor
    }
}

public struct QuotaWindow: Codable, Equatable, Sendable {
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var remainingUnits: String?

    public init(
        label: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        remainingUnits: String? = nil
    ) {
        self.label = label
        self.usedPercent = max(0.0, min(100.0, usedPercent))
        self.resetsAt = resetsAt
        self.remainingUnits = remainingUnits
    }
}

public struct SubscriptionInfo: Codable, Equatable, Sendable {
    public enum Tier: String, Codable, Sendable {
        case free = "Free"
        case pro = "Pro"
        case team = "Team"
        case enterprise = "Enterprise"
        case payAsYouGo = "Pay-As-You-Go"
        case custom = "Custom"
    }

    public enum Status: String, Codable, Sendable {
        case active = "Active"
        case quotaExhausted = "Exhausted"
        case rateLimited = "Rate Limited"
        case expired = "Expired"
        case paymentRequired = "Payment Required"
        case unknown = "Unknown"
    }

    public var tierName: String
    public var tier: Tier
    public var status: Status
    public var renewalDate: Date?
    public var creditsBalanceUSD: Decimal?
    public var quotaWindows: [QuotaWindow]

    public init(
        tierName: String,
        tier: Tier = .custom,
        status: Status = .active,
        renewalDate: Date? = nil,
        creditsBalanceUSD: Decimal? = nil,
        quotaWindows: [QuotaWindow] = []
    ) {
        self.tierName = tierName
        self.tier = tier
        self.status = status
        self.renewalDate = renewalDate
        self.creditsBalanceUSD = creditsBalanceUSD
        self.quotaWindows = quotaWindows
    }
}

public struct WidgetQuotaItem: Codable, Identifiable, Sendable {
    public var id: String
    public var providerID: ProviderID
    public var label: String
    public var tierName: String
    public var usedPercent: Double
    public var remainingUnits: String?
    public var resetsAt: Date?
    public var status: SubscriptionInfo.Status
    public var creditsBalanceUSD: Decimal?
    public var quotaWindows: [QuotaWindow]
    public var isActive: Bool

    public init(
        id: String,
        providerID: ProviderID,
        label: String,
        tierName: String,
        usedPercent: Double,
        remainingUnits: String? = nil,
        resetsAt: Date? = nil,
        status: SubscriptionInfo.Status = .active,
        creditsBalanceUSD: Decimal? = nil,
        quotaWindows: [QuotaWindow] = [],
        isActive: Bool = true
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.tierName = tierName
        self.usedPercent = usedPercent
        self.remainingUnits = remainingUnits
        self.resetsAt = resetsAt
        self.status = status
        self.creditsBalanceUSD = creditsBalanceUSD
        self.quotaWindows = quotaWindows
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case id, providerID, label, tierName, usedPercent, remainingUnits, resetsAt, status, creditsBalanceUSD, quotaWindows, isActive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        providerID = try container.decode(ProviderID.self, forKey: .providerID)
        label = try container.decode(String.self, forKey: .label)
        tierName = try container.decode(String.self, forKey: .tierName)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        remainingUnits = try container.decodeIfPresent(String.self, forKey: .remainingUnits)
        resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        status = try container.decodeIfPresent(SubscriptionInfo.Status.self, forKey: .status) ?? .active
        creditsBalanceUSD = try container.decodeIfPresent(Decimal.self, forKey: .creditsBalanceUSD)
        quotaWindows = try container.decodeIfPresent([QuotaWindow].self, forKey: .quotaWindows) ?? []
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
}

public struct WidgetSnapshot: Codable, Sendable {
    public var updatedAt: Date
    public var items: [WidgetQuotaItem]

    public init(updatedAt: Date = Date(), items: [WidgetQuotaItem] = []) {
        self.updatedAt = updatedAt
        self.items = items
    }
}

public enum WidgetSnapshotStore {
    public static let appGroupID = "TLD3MXMV97.group.com.quotadeck.app"

    public static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static var realHomeDirectoryURL: URL {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var widgetContainerDataURL: URL {
        realHomeDirectoryURL
            .appendingPathComponent("Library/Containers/com.quotadeck.app.widget/Data")
    }

    public static var candidateURLs: [URL] {
        var list: [URL] = []
        if let containerURL = appGroupContainerURL {
            list.append(containerURL.appendingPathComponent("widget_data.json"))
        }
        // Sandboxed widget container paths
        list.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/widget_data.json"))
        list.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quotadeck/widget_data.json"))
        // Explicit widget container paths from real user home
        list.append(widgetContainerDataURL.appendingPathComponent("Documents/widget_data.json"))
        list.append(widgetContainerDataURL.appendingPathComponent(".quotadeck/widget_data.json"))
        list.append(widgetContainerDataURL.appendingPathComponent("widget_data.json"))
        // Real user home directory ~/.quotadeck/
        list.append(realHomeDirectoryURL.appendingPathComponent(".quotadeck/widget_data.json"))
        return list
    }

    public static func save(snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }

        // 1. App Group container if configured
        if let containerURL = appGroupContainerURL {
            let fileURL = containerURL.appendingPathComponent("widget_data.json")
            try? FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }

        // 2. Real home ~/.quotadeck/widget_data.json
        let legacyURL = realHomeDirectoryURL.appendingPathComponent(".quotadeck/widget_data.json")
        try? FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: legacyURL, options: .atomic)

        // 3. Widget container Documents & .quotadeck folders
        let containerDocs = widgetContainerDataURL.appendingPathComponent("Documents/widget_data.json")
        try? FileManager.default.createDirectory(at: containerDocs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: containerDocs, options: .atomic)

        let containerDot = widgetContainerDataURL.appendingPathComponent(".quotadeck/widget_data.json")
        try? FileManager.default.createDirectory(at: containerDot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: containerDot, options: .atomic)
    }

    public static func load() -> WidgetSnapshot {
        for url in candidateURLs {
            if let data = try? Data(contentsOf: url),
               let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
               !snapshot.items.isEmpty {
                return snapshot
            }
        }

        return WidgetSnapshot(updatedAt: Date(), items: [])
    }
}
