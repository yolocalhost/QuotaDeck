import SwiftUI
import WidgetKit
import os
#if canImport(QuotaDeckCore)
import QuotaDeckCore
#endif

private let widgetLog = Logger(subsystem: "com.quotadeck.app.widget", category: "Lifecycle")

struct QuotaTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct QuotaTimelineProvider: TimelineProvider {
    typealias Entry = QuotaTimelineEntry

    func placeholder(in context: Context) -> QuotaTimelineEntry {
        QuotaTimelineEntry(date: Date(), snapshot: sampleSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaTimelineEntry) -> Void) {
        let snapshot = WidgetSnapshotStore.load()
        let entry = QuotaTimelineEntry(
            date: Date(),
            snapshot: snapshot.items.isEmpty ? sampleSnapshot() : snapshot
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaTimelineEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore.load()
        let entry = QuotaTimelineEntry(
            date: Date(),
            snapshot: snapshot.items.isEmpty ? sampleSnapshot() : snapshot
        )
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func sampleSnapshot() -> WidgetSnapshot {
        let now = Date()
        let in2h = now.addingTimeInterval(2 * 3600 + 45 * 60)
        let in6d = now.addingTimeInterval(6 * 86400)
        let in5d = now.addingTimeInterval(5 * 86400 + 12 * 3600)

        return WidgetSnapshot(
            updatedAt: now,
            items: [
                WidgetQuotaItem(
                    id: "sample-codex-1",
                    providerID: .codex,
                    label: "Example Codex Account 1",
                    tierName: "Example Plan",
                    usedPercent: 45,
                    resetsAt: in2h,
                    quotaWindows: [
                        QuotaWindow(label: "5h Session Window", usedPercent: 45, resetsAt: in2h),
                        QuotaWindow(label: "Weekly Quota", usedPercent: 30, resetsAt: in6d)
                    ],
                    isActive: true
                ),
                WidgetQuotaItem(
                    id: "sample-codex-2",
                    providerID: .codex,
                    label: "Example Codex Account 2",
                    tierName: "Example Plan",
                    usedPercent: 25,
                    resetsAt: in6d,
                    quotaWindows: [
                        QuotaWindow(label: "Weekly Quota", usedPercent: 25, resetsAt: in6d),
                        QuotaWindow(label: "5h Session Window", usedPercent: 10, resetsAt: in2h)
                    ],
                    isActive: false
                ),
                WidgetQuotaItem(
                    id: "sample-command-code",
                    providerID: .claudeCode,
                    label: "Example Command Code Account",
                    tierName: "Example Plan",
                    usedPercent: 35,
                    resetsAt: in5d,
                    quotaWindows: [
                        QuotaWindow(label: "Weekly Window", usedPercent: 35, resetsAt: in5d),
                        QuotaWindow(label: "Monthly Credits", usedPercent: 20),
                        QuotaWindow(label: "5-Hour Window", usedPercent: 10)
                    ],
                    isActive: true
                ),
                WidgetQuotaItem(
                    id: "sample-antigravity",
                    providerID: .antigravity,
                    label: "Example Antigravity Account",
                    tierName: "Example Plan",
                    usedPercent: 40,
                    resetsAt: in2h,
                    quotaWindows: [
                        QuotaWindow(label: "Gemini Models (5-Hour)", usedPercent: 40, resetsAt: in2h),
                        QuotaWindow(label: "Gemini Models (Weekly)", usedPercent: 25, resetsAt: in6d)
                    ],
                    isActive: true
                ),
                WidgetQuotaItem(
                    id: "sample-openrouter",
                    providerID: .openRouter,
                    label: "OpenRouter",
                    tierName: "Pay-As-You-Go",
                    usedPercent: 0,
                    creditsBalanceUSD: 10.00,
                    isActive: true
                ),
            ]
        )
    }
}

// MARK: - Helper Formatting & Icons

private func providerShortName(for provider: ProviderID) -> String {
    switch provider {
    case .codex: return "Codex"
    case .claudeCode: return "Command Code"
    case .antigravity: return "Antigravity"
    case .openRouter: return "OpenRouter"
    case .openCode: return "OpenCode"
    }
}

private func iconName(for provider: ProviderID) -> String {
    switch provider {
    case .codex: return "apple.terminal"
    case .claudeCode: return "sparkles"
    case .antigravity: return "globe.americas.fill"
    case .openRouter: return "network"
    case .openCode: return "chevron.left.forwardslash.chevron.right"
    }
}

private func providerColor(for provider: ProviderID) -> Color {
    switch provider {
    case .codex: return Color.green
    case .claudeCode: return Color.orange
    case .antigravity: return Color.blue
    case .openRouter: return Color.purple
    case .openCode: return Color.cyan
    }
}

private func cleanTierBadge(_ tier: String) -> String {
    let t = tier.replacingOccurrences(of: "ChatGPT ", with: "")
                .replacingOccurrences(of: "Antigravity ", with: "")
                .replacingOccurrences(of: "OpenCode ", with: "")
                .trimmingCharacters(in: .whitespaces)
    if t.lowercased() == "pay-as-you-go" { return "PAYG" }
    return t.uppercased()
}

private func shortWindowLabel(_ label: String) -> String {
    if label.contains("Gemini") {
        if label.contains("5-Hour") || label.contains("5h") { return "Gemini 5h" }
        if label.contains("Weekly") { return "Gemini Wk" }
        return "Gemini"
    }
    if label.contains("Claude") || label.contains("GPT") {
        if label.contains("5-Hour") || label.contains("5h") { return "Claude 5h" }
        if label.contains("Weekly") { return "Claude Wk" }
        return "Claude"
    }
    if label.contains("5h Session") || label.contains("5-Hour") {
        return "5h Session"
    }
    if label.contains("Weekly") {
        return "Weekly"
    }
    if label.contains("Monthly") {
        return "Monthly"
    }
    return label
}

private func barColor(for percent: Double) -> Color {
    if percent >= 90 {
        return .red
    } else if percent >= 75 {
        return .orange
    } else {
        return .accentColor
    }
}

private func selectWindowsForDisplay(from windows: [QuotaWindow], maxCount: Int = 2) -> [QuotaWindow] {
    guard windows.count > maxCount else { return windows }
    let sorted = windows.sorted { a, b in
        if (a.usedPercent > 0) != (b.usedPercent > 0) {
            return a.usedPercent > 0
        }
        return a.usedPercent > b.usedPercent
    }
    return Array(sorted.prefix(maxCount))
}

// MARK: - Reusable Views

struct WidgetQuotaBar: View {
    let window: QuotaWindow
    var isCompact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2.5) {
                Text(shortWindowLabel(window.label))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let reset = window.resetsAt, reset > Date() {
                    Text("•")
                        .font(.system(size: 7.5))
                        .foregroundColor(.secondary.opacity(0.4))
                    (Text("in ") + Text(reset, style: .relative))
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 2)

                Text(isCompact ? String(format: "%.0f%%", window.usedPercent) : String(format: "%.0f%% used", window.usedPercent))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(barColor(for: window.usedPercent))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 3.5)
                    Capsule()
                        .fill(barColor(for: window.usedPercent))
                        .frame(
                            width: max(2, min(geo.size.width, geo.size.width * CGFloat(window.usedPercent / 100.0))),
                            height: 3.5
                        )
                }
            }
            .frame(height: 3.5)
        }
    }
}

struct WidgetProviderCard: View {
    let item: WidgetQuotaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: iconName(for: item.providerID))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(providerColor(for: item.providerID))

                Text(providerShortName(for: item.providerID))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Text(cleanTierBadge(item.tierName))
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Color.blue.opacity(0.18))
                    .foregroundColor(.blue)
                    .cornerRadius(3)
            }

            // Content
            if let balance = item.creditsBalanceUSD {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BALANCE")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(String(format: "$%.2f", NSDecimalNumber(decimal: balance).doubleValue))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                }
                .padding(.top, 2)
            } else if !item.quotaWindows.isEmpty {
                let windows = selectWindowsForDisplay(from: item.quotaWindows, maxCount: 2)
                VStack(spacing: 3) {
                    ForEach(windows, id: \.label) { window in
                        WidgetQuotaBar(window: window, isCompact: true)
                    }
                }
            } else {
                WidgetQuotaBar(window: QuotaWindow(label: "Usage", usedPercent: item.usedPercent, resetsAt: item.resetsAt), isCompact: true)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Medium Display Helpers

private func selectMediumDisplayItems(from items: [WidgetQuotaItem]) -> [WidgetQuotaItem] {
    var selected: [WidgetQuotaItem] = []
    var seenProviders = Set<ProviderID>()

    for item in items where item.isActive && !seenProviders.contains(item.providerID) {
        selected.append(item)
        seenProviders.insert(item.providerID)
    }
    for item in items where !seenProviders.contains(item.providerID) && selected.count < 4 {
        selected.append(item)
        seenProviders.insert(item.providerID)
    }
    return Array(selected.prefix(4))
}

private func selectSmallDisplayItems(from items: [WidgetQuotaItem]) -> [WidgetQuotaItem] {
    let activeItems = items.filter { $0.status != .unknown || $0.usedPercent > 0 || $0.creditsBalanceUSD != nil }
    var selected: [WidgetQuotaItem] = []
    var seenProviders = Set<ProviderID>()
    for item in activeItems where item.isActive && !seenProviders.contains(item.providerID) {
        selected.append(item)
        seenProviders.insert(item.providerID)
    }
    for item in activeItems where !seenProviders.contains(item.providerID) && selected.count < 4 {
        selected.append(item)
        seenProviders.insert(item.providerID)
    }
    return Array(selected.prefix(4))
}

// MARK: - Medium Widget (Desktop 2x2 Grid)

struct MediumWidgetView: View {
    let items: [WidgetQuotaItem]

    var body: some View {
        let displayItems = selectMediumDisplayItems(from: items)

        if displayItems.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "gauge.with.needle")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Open QuotaDeck to sync usage")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .containerBackground(for: .widget) { Color.clear }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(displayItems) { item in
                    WidgetProviderCard(item: item)
                }
            }
            .containerBackground(for: .widget) { Color.clear }
        }
    }
}

// MARK: - Small Widget

struct SmallWidgetView: View {
    let items: [WidgetQuotaItem]

    var body: some View {
        let displayItems = selectSmallDisplayItems(from: items)

        if displayItems.count <= 1, let single = displayItems.first {
            WidgetProviderCard(item: single)
                .containerBackground(for: .widget) { Color.clear }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                ForEach(displayItems) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: iconName(for: item.providerID))
                                .font(.system(size: 9))
                                .foregroundColor(providerColor(for: item.providerID))
                            Text(providerShortName(for: item.providerID))
                                .font(.system(size: 9, weight: .bold))
                                .lineLimit(1)
                        }
                        if let balance = item.creditsBalanceUSD {
                            Text(String(format: "$%.2f", NSDecimalNumber(decimal: balance).doubleValue))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.green)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("\(Int(item.usedPercent))%")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(barColor(for: item.usedPercent))

                                if let reset = item.resetsAt, reset > Date() {
                                    Text(reset, style: .relative)
                                        .font(.system(size: 7.5))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 3)
                                    Capsule().fill(barColor(for: item.usedPercent))
                                        .frame(width: max(2, min(geo.size.width, geo.size.width * CGFloat(item.usedPercent / 100.0))), height: 3)
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
            }
            .containerBackground(for: .widget) { Color.clear }
        }
    }
}

// MARK: - Large Widget (All Available Profiles)

struct LargeWidgetView: View {
    let items: [WidgetQuotaItem]

    var body: some View {
        let activeItems = items.filter { $0.status != .unknown || $0.usedPercent > 0 || $0.creditsBalanceUSD != nil }
        let displayItems = activeItems.isEmpty ? items : activeItems
        let maxWindowsPerCard = displayItems.count > 4 ? 2 : 4

        VStack(alignment: .leading, spacing: 5) {
            ForEach(displayItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: iconName(for: item.providerID))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(providerColor(for: item.providerID))

                        Text(providerShortName(for: item.providerID))
                            .font(.system(size: 11, weight: .bold))

                        if !item.label.isEmpty && item.label != providerShortName(for: item.providerID) {
                            Text(item.label)
                                .font(.system(size: 9.5))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 2)

                        Text(cleanTierBadge(item.tierName))
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color.blue.opacity(0.18))
                            .foregroundColor(.blue)
                            .cornerRadius(3)

                        if item.isActive && item.providerID == .codex {
                            Text("ACTIVE")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.18))
                                .foregroundColor(.green)
                                .cornerRadius(3)
                        }
                    }

                    if let balance = item.creditsBalanceUSD {
                        HStack {
                            Text("Credit Balance")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "$%.2f", NSDecimalNumber(decimal: balance).doubleValue))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.green)
                        }
                    } else if !item.quotaWindows.isEmpty {
                        let windows = selectWindowsForDisplay(from: item.quotaWindows, maxCount: maxWindowsPerCard)
                        VStack(spacing: 2.5) {
                            ForEach(windows, id: \.label) { window in
                                WidgetQuotaBar(window: window, isCompact: false)
                            }
                        }
                    } else {
                        WidgetQuotaBar(window: QuotaWindow(label: "Usage", usedPercent: item.usedPercent, resetsAt: item.resetsAt), isCompact: false)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(item.isActive ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(item.isActive ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 0.5)
                )
            }

            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Root Widget Entry View

struct QuotaWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: QuotaTimelineEntry

    var body: some View {
        let items = entry.snapshot.items

        switch family {
        case .systemMedium:
            MediumWidgetView(items: items)
        case .systemSmall:
            SmallWidgetView(items: items)
        case .systemLarge:
            LargeWidgetView(items: items)
        default:
            MediumWidgetView(items: items)
        }
    }
}

struct QuotaDeckWidget: Widget {
    let kind: String = "QuotaDeckWidget"

    init() {
        widgetLog.notice("QuotaDeckWidget.init() invoked")
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("QuotaDeck Usage")
        .description("Track AI quota and rate limit usage across accounts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct QuotaDeckWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuotaDeckWidget()
    }
}
