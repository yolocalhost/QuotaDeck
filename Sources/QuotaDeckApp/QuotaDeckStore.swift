import Foundation
import QuotaDeckCore
import SwiftUI
import WidgetKit

@MainActor
public final class QuotaDeckStore: ObservableObject {
    @Published public var profiles: [AccountProfile] = []
    @Published public var subscriptions: [String: SubscriptionInfo] = [:]
    @Published public var isRefreshing: Bool = false
    @Published public var lastRefreshedAt: Date?
    @Published public var isCodexLoggingIn: Bool = false
    @Published public var codexLoginError: String?

    private var lastAutoSwitchAttempt: Date?
    private var lastContinuedTurnID: String?

    private let configURL: URL
    private let credentialStore: CredentialStore

    private let providers: [ProviderID: any QuotaProvider]

    public init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".quotadeck/profiles.json"),
        credentialStore: CredentialStore = KeychainCredentialStore.shared
    ) {
        UserDefaults.standard.register(defaults: [
            "autoSwitchWhenExhausted": true,
            "showPercentageInMenuBar": true,
            "refreshIntervalMinutes": 5
        ])

        self.configURL = configURL
        self.credentialStore = credentialStore

        self.providers = [
            .codex: CodexProvider(),
            .openCode: OpenCodeProvider(credentialStore: credentialStore),
            .claudeCode: CommandCodeProvider(credentialStore: credentialStore),
            .antigravity: AntigravityProvider(),
            .openRouter: OpenRouterProvider(credentialStore: credentialStore),
        ]

        loadProfiles()
    }

    public func loadProfiles() {
        if let data = try? Data(contentsOf: configURL),
           var saved = try? JSONDecoder().decode([AccountProfile].self, from: data), !saved.isEmpty {
            for i in saved.indices {
                if saved[i].providerID == .claudeCode && saved[i].label == "Claude Code" {
                    saved[i].label = "Command Code"
                }
            }
            self.profiles = saved
        } else {
            // Seed initial profiles for all supported providers
            self.profiles = [
                AccountProfile(id: "commandcode-default", providerID: .claudeCode, label: "Command Code", isActive: true),
                AccountProfile(id: "opencode-default", providerID: .openCode, label: "OpenCode Go", isActive: true),
                AccountProfile(id: "antigravity-default", providerID: .antigravity, label: "Antigravity", isActive: true),
                AccountProfile(id: "openrouter-default", providerID: .openRouter, label: "OpenRouter", isActive: true),
            ]
        }

        if let antigravityEmail = AntigravityProvider.discoverUserEmail() {
            for i in self.profiles.indices {
                if self.profiles[i].providerID == .antigravity {
                    self.profiles[i].accountEmail = antigravityEmail
                    if self.profiles[i].label == "Antigravity" {
                        self.profiles[i].label = antigravityEmail
                    }
                }
            }
        }

        // Auto-discover Codex profiles from ~/.codex-switcher if available
        syncCodexProfiles()
        saveProfiles()
    }

    public func syncCodexProfiles() {
        let discovered = CodexProvider.discoverProfiles()
        if !discovered.isEmpty {
            // Remove old dummy codex profiles
            self.profiles.removeAll { $0.providerID == .codex }
            self.profiles.insert(contentsOf: discovered, at: 0)
            saveProfiles()
        }
    }

    public func loginNewCodexProfile(customLabel: String?) async {
        isCodexLoggingIn = true
        codexLoginError = nil
        do {
            let (authData, email) = try await CodexProvider.startIsolatedLogin()
            let newID = String(Int(Date().timeIntervalSince1970))
            let label = (customLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? customLabel! : (email ?? "Codex \(newID)")

            let codexProvider = (providers[.codex] as? CodexProvider) ?? CodexProvider()
            try codexProvider.saveNewProfile(id: newID, label: label, authData: authData, makeActive: false)

            let profile = AccountProfile(
                id: newID,
                providerID: .codex,
                label: label,
                accountEmail: email,
                isActive: false
            )
            self.profiles.append(profile)
            saveProfiles()
            await refreshProfile(profile)
            isCodexLoggingIn = false
        } catch {
            codexLoginError = error.localizedDescription
            isCodexLoggingIn = false
        }
    }

    public func cancelCodexLogin() {
        CodexProvider.cancelActiveLogin()
        isCodexLoggingIn = false
    }

    public func captureLiveCodexSession(label: String) throws {
        let liveAuth = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: liveAuth.path) else {
            throw NSError(domain: "CodexProvider", code: 404, userInfo: [NSLocalizedDescriptionKey: "No active session found in ~/.codex/auth.json."])
        }
        let data = try Data(contentsOf: liveAuth)
        let email = CodexProvider.emailFromAuthData(data)
        let newID = String(Int(Date().timeIntervalSince1970))
        let finalLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (email ?? "Codex \(newID)") : label

        let codexProvider = (providers[.codex] as? CodexProvider) ?? CodexProvider()
        try codexProvider.saveNewProfile(id: newID, label: finalLabel, authData: data, makeActive: false)

        let profile = AccountProfile(
            id: newID,
            providerID: .codex,
            label: finalLabel,
            accountEmail: email,
            isActive: false
        )
        self.profiles.append(profile)
        saveProfiles()
        Task {
            await refreshProfile(profile)
        }
    }

    public func saveProfiles() {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: configURL, options: .atomic)
        }
        exportWidgetSnapshot()
    }

    public func addProfile(providerID: ProviderID, label: String, email: String? = nil) {
        let newProfile = AccountProfile(
            providerID: providerID,
            label: label,
            accountEmail: email,
            isActive: profiles.filter { $0.providerID == providerID }.isEmpty
        )
        profiles.append(newProfile)
        saveProfiles()
        Task {
            await refreshProfile(newProfile)
        }
    }

    public func removeProfile(id: String) {
        profiles.removeAll { $0.id == id }
        subscriptions.removeValue(forKey: id)
        saveProfiles()
    }

    public func setActiveProfile(id: String) {
        guard let target = profiles.first(where: { $0.id == id }) else { return }
        for idx in profiles.indices {
            if profiles[idx].providerID == target.providerID {
                profiles[idx].isActive = (profiles[idx].id == id)
            }
        }
        saveProfiles()

        if let provider = providers[target.providerID], provider.capabilities.contains(.profileSwitching) {
            Task {
                try? await provider.switchActiveProfile(to: id)
            }
        }
    }

    public func credentialService(for providerID: ProviderID) -> String {
        switch providerID {
        case .openCode: return OpenCodeProvider.serviceName
        case .openRouter: return OpenRouterProvider.serviceName
        case .claudeCode: return CommandCodeProvider.serviceName
        case .codex: return "com.quotadeck.codex"
        case .antigravity: return "com.quotadeck.antigravity"
        }
    }

    public func saveCredential(secret: String, for profile: AccountProfile) {
        let service = credentialService(for: profile.providerID)
        try? credentialStore.save(secret: secret, service: service, account: profile.id)
        Task {
            await refreshProfile(profile)
        }
    }

    public func loadCredential(for profile: AccountProfile) -> String? {
        let service = credentialService(for: profile.providerID)
        return credentialStore.load(service: service, account: profile.id)
    }

    public func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            for profile in self.profiles {
                await self.refreshProfile(profile)
            }
            self.lastRefreshedAt = Date()
            self.isRefreshing = false
            self.checkAutoSwitchCodex()
            self.exportWidgetSnapshot()
        }
    }

    public func checkAutoSwitchCodex() {
        guard UserDefaults.standard.bool(forKey: "autoSwitchWhenExhausted") else { return }

        // Cooldown: at least 30s between automatic switch attempts
        if let lastAttempt = lastAutoSwitchAttempt, Date().timeIntervalSince(lastAttempt) < 30 {
            return
        }

        let codexProfiles = profiles.filter { $0.providerID == .codex }
        guard codexProfiles.count > 1 else { return }
        guard let activeCodex = codexProfiles.first(where: { $0.isActive }) else { return }

        let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let interrupted = CodexProvider.latestInterruptedTask(codexHome: codexHome)

        let activeSub = subscriptions[activeCodex.id]
        let quotaWindows = activeSub?.quotaWindows ?? []
        let highestUsed = quotaWindows.map(\.usedPercent).max() ?? 0.0

        let isInterruptedNew = (interrupted != nil && interrupted?.turnID != lastContinuedTurnID)
        let isExhausted = isInterruptedNew || (activeSub?.status == .quotaExhausted) || (highestUsed >= 90.0)

        guard isExhausted else { return }

        // Find alternate Codex profile with lowest usage that is < 90%
        let candidates = codexProfiles.filter { !$0.isActive }
        let bestTarget = candidates.min { a, b in
            let subA = subscriptions[a.id]?.quotaWindows.map(\.usedPercent).max() ?? 0
            let subB = subscriptions[b.id]?.quotaWindows.map(\.usedPercent).max() ?? 0
            return subA < subB
        }

        guard let target = bestTarget else { return }
        let targetMaxUsed = subscriptions[target.id]?.quotaWindows.map(\.usedPercent).max() ?? 0
        guard targetMaxUsed < 90.0 else { return }

        lastAutoSwitchAttempt = Date()
        if let turnID = interrupted?.turnID {
            lastContinuedTurnID = turnID
        }

        setActiveProfile(id: target.id)
    }

    public func refreshProfile(_ profile: AccountProfile) async {
        guard let provider = providers[profile.providerID] else { return }

        if profile.providerID == .antigravity && (profile.accountEmail == nil || profile.accountEmail?.isEmpty == true) {
            if let email = AntigravityProvider.discoverUserEmail(), !email.isEmpty {
                if let idx = self.profiles.firstIndex(where: { $0.id == profile.id }) {
                    self.profiles[idx].accountEmail = email
                    if self.profiles[idx].label == "Antigravity" {
                        self.profiles[idx].label = email
                    }
                    self.saveProfiles()
                }
            }
        }

        do {
            var sub = try await provider.fetchSubscription(account: profile)
            if profile.providerID == .claudeCode {
                if let override = UserDefaults.standard.string(forKey: "commandCodePlanOverride"), !override.isEmpty, override != "Auto-Detect" {
                    sub.tierName = override
                }
            }
            self.subscriptions[profile.id] = sub
        } catch {
            self.subscriptions[profile.id] = SubscriptionInfo(
                tierName: profile.providerID.displayName,
                tier: .custom,
                status: .unknown,
                quotaWindows: []
            )
        }
        exportWidgetSnapshot()
    }

    public func exportWidgetSnapshot() {
        var items: [WidgetQuotaItem] = []

        // Sort profiles: Codex active first, other Codex profiles, then other providers
        let codexProfiles = profiles.filter { $0.providerID == .codex }
            .sorted { a, b in
                if a.isActive != b.isActive { return a.isActive && !b.isActive }
                return a.label < b.label
            }
        let otherProfiles = profiles.filter { $0.providerID != .codex }
            .sorted { a, b in
                if a.isActive != b.isActive { return a.isActive && !b.isActive }
                return a.providerID.rawValue < b.providerID.rawValue
            }

        let allProfiles = codexProfiles + otherProfiles

        for profile in allProfiles {
            if let sub = subscriptions[profile.id] {
                let maxWindow = sub.quotaWindows.max { a, b in a.usedPercent < b.usedPercent }
                let used = maxWindow?.usedPercent ?? 0.0
                items.append(WidgetQuotaItem(
                    id: profile.id,
                    providerID: profile.providerID,
                    label: profile.label,
                    tierName: sub.tierName,
                    usedPercent: used,
                    remainingUnits: maxWindow?.remainingUnits,
                    resetsAt: maxWindow?.resetsAt,
                    status: sub.status,
                    creditsBalanceUSD: sub.creditsBalanceUSD,
                    quotaWindows: sub.quotaWindows,
                    isActive: profile.isActive
                ))
            } else {
                items.append(WidgetQuotaItem(
                    id: profile.id,
                    providerID: profile.providerID,
                    label: profile.label,
                    tierName: profile.providerID.displayName,
                    usedPercent: 0,
                    status: .unknown,
                    quotaWindows: [],
                    isActive: profile.isActive
                ))
            }
        }

        let snapshot = WidgetSnapshot(updatedAt: Date(), items: items)
        WidgetSnapshotStore.save(snapshot: snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
