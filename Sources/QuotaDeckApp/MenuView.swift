import SwiftUI
import QuotaDeckCore

public struct MenuView: View {
    @ObservedObject var store: QuotaDeckStore
    var openSettings: () -> Void
    var quitApp: () -> Void

    public init(
        store: QuotaDeckStore,
        openSettings: @escaping () -> Void,
        quitApp: @escaping () -> Void
    ) {
        self.store = store
        self.openSettings = openSettings
        self.quitApp = quitApp
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("QuotaDeck")
                    .font(.headline)
                Spacer()
                if store.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                } else {
                    Button(action: { store.refreshAll() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh Quotas")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    // 1. OpenAI Codex Multi-Account Section
                    let codexProfiles = store.profiles.filter { $0.providerID == .codex }
                    if !codexProfiles.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("OPENAI CODEX")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(codexProfiles.count) accounts")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 2)

                            ForEach(codexProfiles) { profile in
                                let sub = store.subscriptions[profile.id]
                                CodexProfileCard(
                                    profile: profile,
                                    subscription: sub,
                                    isActive: profile.isActive,
                                    onSwitch: {
                                        store.setActiveProfile(id: profile.id)
                                    }
                                )
                            }
                        }
                    }

                    // 2. Other Providers Section
                    let otherProfiles = store.profiles.filter { $0.providerID != .codex && $0.isActive }
                    if !otherProfiles.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PROVIDERS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 2)

                            ForEach(otherProfiles) { profile in
                                let sub = store.subscriptions[profile.id]
                                CompactProviderCard(store: store, profile: profile, subscription: sub)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 520)

            Divider()

            // Footer
            HStack {
                Button("Settings...") {
                    openSettings()
                }
                .buttonStyle(.plain)
                .font(.subheadline)

                Spacer()

                Button("Quit") {
                    quitApp()
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 350)
    }
}

struct CodexProfileCard: View {
    let profile: AccountProfile
    let subscription: SubscriptionInfo?
    let isActive: Bool
    let onSwitch: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSwitch) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(isActive ? .accentColor : .secondary)
                        .font(.system(size: 13))

                    Text(profile.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer()

                    if let sub = subscription {
                        Text(sub.tierName.replacingOccurrences(of: "ChatGPT ", with: "").uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }

                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }

                if let sub = subscription, !sub.quotaWindows.isEmpty {
                    VStack(spacing: 5) {
                        ForEach(sub.quotaWindows, id: \.label) { window in
                            QuotaBarView(window: window)
                        }
                    }
                    .padding(.top, 2)
                } else {
                    Text("No usage data")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor.opacity(0.08) : (isHovered ? Color.secondary.opacity(0.1) : Color(NSColor.controlBackgroundColor).opacity(0.6)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct CompactProviderCard: View {
    @ObservedObject var store: QuotaDeckStore
    let profile: AccountProfile
    let subscription: SubscriptionInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.providerID.displayName)
                        .font(.subheadline.bold())
                    if let email = profile.accountEmail, !email.isEmpty, email != profile.providerID.displayName {
                        Text(email)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else if profile.providerID == .antigravity {
                        Text("macOS Keychain (gemini/antigravity)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let sub = subscription {
                    Text(sub.tierName)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(4)
                }
            }

            if let sub = subscription {
                if let credits = sub.creditsBalanceUSD {
                    HStack {
                        Text("Balance")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "$%.2f", NSDecimalNumber(decimal: credits).doubleValue))
                            .font(.caption.bold())
                            .foregroundColor(.green)
                    }
                }

                if sub.quotaWindows.isEmpty && sub.creditsBalanceUSD == nil {
                    Text(sub.status.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(sub.quotaWindows, id: \.label) { window in
                        QuotaBarView(window: window)
                    }
                }
            } else {
                Text("Fetching usage...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
    }
}
