// Owner: claude-app. Claude usage limits under the session list (SPEC §A.5, §D.9):
//
//   5h  ━━━━━━━──── 62 %
//   7d  ━━━─────── 31 %
//
// Two 3 pt bars. Neutral below the warning threshold, orange at it, red at ≥ 95 %. Hover shows the reset
// times. Hidden until the statusLine bridge has delivered data (Pro/Max, after the first response).

import SuperNotchCore
import SwiftUI

struct UsageBarsView: View {
    @Environment(ClaudeSessionsModel.self) private var claude
    @Environment(SettingsStore.self) private var store

    @State private var isHovering = false

    init() {}

    var body: some View {
        let settings = store.settings
        if settings.showUsageLimits, let usage = claude.usage, usage.fiveHour != nil || usage.sevenDay != nil {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                if let window = usage.fiveHour {
                    UsageBarRow(
                        label: "5h", window: window, threshold: settings.usageWarningThreshold,
                        showsReset: isHovering)
                }
                if let window = usage.sevenDay {
                    UsageBarRow(
                        label: "7d", window: window, threshold: settings.usageWarningThreshold,
                        showsReset: isHovering)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(DesignTokens.Motion.hover) { isHovering = hovering }
            }
            .help(tooltip(for: usage))
            .accessibilityElement(children: .combine)
        }
    }

    private func tooltip(for usage: UsageLimits) -> String {
        let now = Date()
        var lines: [String] = []
        if let window = usage.fiveHour {
            lines.append("5-hour limit: \(ClaudeFormat.percent(window.usedPercentage)) used. "
                + ClaudeFormat.resetDescription(window.resetsAt, now: now) + ".")
        }
        if let window = usage.sevenDay {
            lines.append("Weekly limit: \(ClaudeFormat.percent(window.usedPercentage)) used. "
                + ClaudeFormat.resetDescription(window.resetsAt, now: now) + ".")
        }
        lines.append("Claude Code usage, \(ClaudeFormat.updatedDescription(usage.updatedAt, now: now)).")
        return lines.joined(separator: "\n")
    }
}

private struct UsageBarRow: View {
    let label: String
    let window: UsageWindow
    let threshold: Double
    let showsReset: Bool

    var body: some View {
        let color = DesignTokens.Colors.usage(fraction: window.fraction, threshold: threshold)
        HStack(spacing: DesignTokens.Spacing.s) {
            Text(label)
                .font(DesignTokens.Fonts.micro)
                .foregroundStyle(DesignTokens.Colors.tertiaryText)
                .frame(width: 16, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignTokens.Colors.trackFill)
                    Capsule()
                        .fill(color)
                        .frame(width: max(proxy.size.width * window.fraction, window.fraction > 0 ? 3 : 0))
                }
            }
            .frame(height: NotchMetrics.usageBarHeight)
            Text(trailingText)
                .font(DesignTokens.Fonts.rowMeta)
                .foregroundStyle(window.fraction >= threshold ? color : DesignTokens.Colors.secondaryText)
                .lineLimit(1)
                .frame(width: showsReset ? 78 : 34, alignment: .trailing)
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label == "5h" ? "5-hour" : "Weekly") usage \(ClaudeFormat.percent(window.usedPercentage))")
    }

    private var trailingText: String {
        guard showsReset, let resetsAt = window.resetsAt else { return ClaudeFormat.percent(window.usedPercentage) }
        return "↻ " + ClaudeFormat.countdown(to: resetsAt, now: Date()).replacingOccurrences(of: "in ", with: "")
    }
}
