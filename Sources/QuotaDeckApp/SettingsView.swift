import SwiftUI
import QuotaDeckCore

public struct SettingsView: View {
    @ObservedObject var store: QuotaDeckStore
    @State private var selectedTab = 0

    public init(store: QuotaDeckStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Picker("", selection: $selectedTab) {
                    Label("Profiles & Accounts", systemImage: "person.2.fill").tag(0)
                    Label("Subscriptions & Quotas", systemImage: "creditcard.fill").tag(1)
                    Label("General", systemImage: "gearshape.fill").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)

            Divider()

            Group {
                switch selectedTab {
                case 0:
                    ProfilesTab(store: store)
                case 1:
                    SubscriptionsTab(store: store)
                case 2:
                    GeneralTab(store: store)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity, alignment: .top)
    }
}

struct ProfilesTab: View {
    @ObservedObject var store: QuotaDeckStore
    @State private var selectedProvider: ProviderID = .codex
    @State private var newProfileLabel = ""
    @State private var newProfileEmail = ""
    @State private var showingAddSheet = false

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar by provider
            List(selection: $selectedProvider) {
                Section("Providers") {
                    ForEach(ProviderID.allCases, id: \.self) { provider in
                        HStack {
                            Text(provider.displayName)
                            Spacer()
                            let count = store.profiles.filter { $0.providerID == provider }.count
                            Text("\(count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .tag(provider)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            // Details panel for selected provider
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(selectedProvider.displayName)
                        .font(.title2.bold())
                    Spacer()
                    if selectedProvider == .codex {
                        Button(action: { store.syncCodexProfiles(); store.refreshAll() }) {
                            Label("Sync Codex Switcher", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    Button(action: { showingAddSheet = true }) {
                        Label("Add Profile", systemImage: "plus")
                    }
                }

                let providerProfiles = store.profiles.filter { $0.providerID == selectedProvider }

                if providerProfiles.isEmpty {
                    Text("No profiles configured for \(selectedProvider.displayName).")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(providerProfiles) { profile in
                            ProfileRowView(store: store, profile: profile)
                        }
                    }
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingAddSheet) {
            VStack(spacing: 16) {
                Text("Add \(selectedProvider.displayName) Profile")
                    .font(.headline)

                if selectedProvider == .codex {
                    if store.isCodexLoggingIn {
                        VStack(spacing: 12) {
                            ProgressView("Waiting for OpenAI authorization in browser...")
                                .padding()
                            Button("Cancel Login") {
                                store.cancelCodexLogin()
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("Profile Label (optional)", text: $newProfileLabel)
                                .textFieldStyle(.roundedBorder)

                            Button(action: {
                                Task {
                                    await store.loginNewCodexProfile(customLabel: newProfileLabel.isEmpty ? nil : newProfileLabel)
                                    if store.codexLoginError == nil {
                                        showingAddSheet = false
                                        newProfileLabel = ""
                                    }
                                }
                            }) {
                                Label("Log In via Browser (codex login)", systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Divider()

                            Button(action: {
                                do {
                                    try store.captureLiveCodexSession(label: newProfileLabel)
                                    showingAddSheet = false
                                    newProfileLabel = ""
                                } catch {
                                    store.codexLoginError = error.localizedDescription
                                }
                            }) {
                                Label("Capture Active ~/.codex Session", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }

                            if let err = store.codexLoginError {
                                Text(err)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }

                            HStack {
                                Spacer()
                                Button("Close") {
                                    showingAddSheet = false
                                    newProfileLabel = ""
                                    store.codexLoginError = nil
                                }
                            }
                        }
                    }
                } else {
                    TextField("Profile Label (e.g. Work, Personal)", text: $newProfileLabel)
                        .textFieldStyle(.roundedBorder)

                    TextField("Email (optional)", text: $newProfileEmail)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Cancel") {
                            showingAddSheet = false
                            newProfileLabel = ""
                            newProfileEmail = ""
                        }
                        Spacer()
                        Button("Add") {
                            if !newProfileLabel.isEmpty {
                                store.addProfile(providerID: selectedProvider, label: newProfileLabel, email: newProfileEmail.isEmpty ? nil : newProfileEmail)
                                showingAddSheet = false
                                newProfileLabel = ""
                                newProfileEmail = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newProfileLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(24)
            .frame(width: 380)
        }
    }
}

struct ProfileRowView: View {
    @ObservedObject var store: QuotaDeckStore
    let profile: AccountProfile

    @State private var credentialText: String = ""
    @State private var hasCredential: Bool = false
    @State private var isEditingCredential: Bool = false
    @State private var showPlainKey: Bool = false
    @AppStorage("commandCodePlanOverride") private var commandCodePlan: String = "Auto-Detect"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: { store.setActiveProfile(id: profile.id) }) {
                    Image(systemName: profile.isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(profile.isActive ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(profile.label)
                            .font(.headline)
                        if profile.isActive {
                            Text("ACTIVE")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    if let email = profile.accountEmail {
                        Text(email)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(role: .destructive, action: { store.removeProfile(id: profile.id) }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            // Credential management section
            if profile.providerID == .codex {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("OAuth session managed via ~/.codex-switcher & ~/.codex/auth.json")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 8) {
                    if isEditingCredential {
                        if showPlainKey {
                            TextField("Enter API Key / Token", text: $credentialText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 240)
                        } else {
                            SecureField("Enter API Key / Token", text: $credentialText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 240)
                        }

                        Button(action: { showPlainKey.toggle() }) {
                            Image(systemName: showPlainKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .help("Toggle visibility")

                        Button("Paste") {
                            if let pasted = NSPasteboard.general.string(forType: .string) {
                                credentialText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }

                        Button("Save") {
                            store.saveCredential(secret: credentialText, for: profile)
                            isEditingCredential = false
                            hasCredential = true
                            credentialText = ""
                            showPlainKey = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(credentialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Cancel") {
                            isEditingCredential = false
                            credentialText = ""
                            showPlainKey = false
                        }
                    } else {
                        Text(hasCredential ? "••••••••••••••••" : "No credential stored")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(hasCredential ? "Update Key" : "Add Key") {
                            isEditingCredential = true
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 4)
            }

            if profile.providerID == .claudeCode {
                HStack(spacing: 8) {
                    Text("Plan Tier:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $commandCodePlan) {
                        Text("Auto-Detect (Caps)").tag("Auto-Detect")
                        Text("Go").tag("Go")
                        Text("GOAT").tag("GOAT")
                        Text("Pro").tag("Pro")
                        Text("Max").tag("Max")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                    .onChange(of: commandCodePlan) { _, _ in
                        store.refreshAll()
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            hasCredential = (store.loadCredential(for: profile) != nil)
        }
    }
}

struct SubscriptionsTab: View {
    @ObservedObject var store: QuotaDeckStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Detected Subscriptions & Quotas")
                    .font(.title2.bold())
                Spacer()
                Button(action: { store.refreshAll() }) {
                    Label(store.isRefreshing ? "Refreshing..." : "Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
            .padding([.horizontal, .top])

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.profiles) { profile in
                        let sub = store.subscriptions[profile.id]
                        SubscriptionCardView(profile: profile, subscription: sub)
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SubscriptionCardView: View {
    let profile: AccountProfile
    let subscription: SubscriptionInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.providerID.displayName)
                            .font(.headline)
                        if profile.isActive {
                            Text("ACTIVE")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .foregroundColor(.green)
                                .cornerRadius(4)
                        }
                    }
                    Text(profile.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let sub = subscription {
                    Text(sub.tierName)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(6)

                    StatusBadgeView(status: sub.status)
                } else {
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let sub = subscription {
                if let credits = sub.creditsBalanceUSD {
                    Text(String(format: "Credits Balance: $%.2f", NSDecimalNumber(decimal: credits).doubleValue))
                        .font(.subheadline.bold())
                        .foregroundColor(.green)
                }

                if !sub.quotaWindows.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(sub.quotaWindows, id: \.label) { window in
                            QuotaBarView(window: window)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct StatusBadgeView: View {
    let status: SubscriptionInfo.Status

    var body: some View {
        Text(status.rawValue)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(6)
    }

    var color: Color {
        switch status {
        case .active: return .green
        case .quotaExhausted: return .red
        case .rateLimited: return .orange
        case .expired, .paymentRequired: return .purple
        case .unknown: return .gray
        }
    }
}

struct QuotaBarView: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.caption)

                if let reset = window.resetsAt, reset > Date() {
                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.5))
                    (Text("in ") + Text(reset, style: .relative))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()
                if let units = window.remainingUnits {
                    Text(units)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(String(format: "%.0f%% used", window.usedPercent))
                    .font(.caption.bold())
                    .foregroundColor(window.usedPercent >= 90 ? .red : .primary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(for: window.usedPercent))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(window.usedPercent / 100.0))), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    func barColor(for pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 75 { return .orange }
        return .accentColor
    }
}

struct GeneralTab: View {
    @ObservedObject var store: QuotaDeckStore
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 5
    @AppStorage("showPercentageInMenuBar") private var showPercentageInMenuBar = true
    @AppStorage("autoSwitchWhenExhausted") private var autoSwitchWhenExhausted = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("General Settings")
                    .font(.title2.bold())

                Form {
                    Section("OpenAI Codex Automation") {
                        Toggle("Automatically switch Codex profile when quota is exhausted", isOn: $autoSwitchWhenExhausted)
                        Text("When the active account reaches 100% usage (5h or weekly window), QuotaDeck automatically switches to the next non-exhausted account and restarts Codex Desktop.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Section("Menu Bar Appearance") {
                        Toggle("Show highest quota percentage in menu bar", isOn: $showPercentageInMenuBar)
                    }

                    Section("Refresh Rate") {
                        Picker("Background Refresh Interval", selection: $refreshIntervalMinutes) {
                            Text("1 minute").tag(1)
                            Text("5 minutes").tag(5)
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                        }
                    }

                    Section("About") {
                        HStack {
                            Text("QuotaDeck")
                                .font(.headline)
                            Text("v0.1.0")
                                .foregroundColor(.secondary)
                        }
                        Text("Unified AI Quota, Subscription & Profile Manager for macOS.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
