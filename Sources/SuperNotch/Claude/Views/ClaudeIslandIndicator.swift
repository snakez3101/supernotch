// Owner: claude-app. Right wing of the closed island while Claude is 🟡/🔴 (SPEC §A.2, §D.10):
// one 6 pt dot per visible session (most urgent first, 3 pt spacing, up to 4) plus the orange usage-warning
// dot. NotchSlots shows this view only in that case and draws the warning dot itself otherwise.

import SuperNotchCore
import SwiftUI

struct ClaudeIslandIndicator: View {
    @Environment(ClaudeSessionsModel.self) private var claude
    @Environment(SettingsStore.self) private var store

    init() {}

    var body: some View {
        let settings = store.settings
        let showsWarning = settings.showUsageLimits && claude.isUsageWarning
        // 36 pt wing: 4 dots (33 pt), or 3 dots + the warning dot (32 pt).
        let maxDots = showsWarning ? NotchMetrics.claudeMaxDots - 1 : NotchMetrics.claudeMaxDots
        let lights = Array(claude.sessions.prefix(maxDots).map(\.trafficLight))
        HStack(spacing: NotchMetrics.claudeDotSpacing) {
            ForEach(Array(lights.enumerated()), id: \.offset) { _, light in
                ClaudeTrafficDot(light: light, diameter: NotchMetrics.claudeDotDiameter)
            }
            if showsWarning {
                Circle()
                    .fill(DesignTokens.Colors.warningOrange)
                    .frame(width: NotchMetrics.warningDotDiameter, height: NotchMetrics.warningDotDiameter)
                    .padding(.leading, lights.isEmpty ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(showsWarning: showsWarning))
    }

    private func accessibilityText(showsWarning: Bool) -> String {
        let sessions = claude.sessions
        let red = sessions.filter { $0.trafficLight == .red }.count
        let yellow = sessions.filter { $0.trafficLight == .yellow }.count
        var parts: [String] = []
        if red > 0 { parts.append("\(red) Claude session\(red == 1 ? "" : "s") need you") }
        if yellow > 0 { parts.append("\(yellow) working") }
        if showsWarning { parts.append("usage limit warning") }
        return parts.isEmpty ? "Claude" : parts.joined(separator: ", ")
    }
}
