// Owner: claude-app. One compact session row in the Home tab (SPEC §A.5): 26 pt tall.
//
//   ● Fix login bug   +2  ⚠        supernotch   2m
//
// Click = jump to the chat (SPEC §D.8). Rows get no glass of their own (§A.3), only a hover highlight.

import SuperNotchCore
import SwiftUI

struct SessionRowView: View {
    let session: Session
    var onOpen: () -> Void = {}

    @State private var isHovering = false

    init(session: Session, onOpen: @escaping () -> Void = {}) {
        self.session = session
        self.onOpen = onOpen
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s + 1) {
            ClaudeTrafficDot(
                light: session.trafficLight, isAnimated: !session.isStale, isDimmed: session.isStale)
            Text(session.displayTitle)
                .font(DesignTokens.Fonts.rowTitle)
                .foregroundStyle(DesignTokens.Colors.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            badges
            Spacer(minLength: DesignTokens.Spacing.xs)
            Text(session.projectName)
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 84, alignment: .trailing)
            meta
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.horizontal, DesignTokens.Spacing.s)
        .frame(height: NotchMetrics.claudeRowHeight)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.medium - 2, style: .continuous)
                .fill(isHovering ? DesignTokens.Colors.hoverFill : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.hover) { isHovering = hovering }
        }
        .onTapGesture { onOpen() }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.displayTitle), \(session.projectName), \(ClaudeFormat.status(of: session))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }

    @ViewBuilder
    private var badges: some View {
        if session.activeSubagents > 0 {
            Text("+\(session.activeSubagents)")
                .font(DesignTokens.Fonts.micro)
                .foregroundStyle(DesignTokens.Colors.secondaryText)
                .padding(.horizontal, 4)
                .frame(height: 13)
                .background(DesignTokens.Colors.controlFill, in: Capsule())
                .help("\(session.activeSubagents) subagent(s) running")
        }
        if session.hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.warningOrange)
                .help(session.lastError ?? "Stopped with an error")
        }
    }

    /// Relative time since the last phase change, or a short state for 🔴. Refreshes twice a minute while
    /// the row is on screen (the Home tab is visible only while expanded).
    @ViewBuilder
    private var meta: some View {
        switch session.phase {
        case .needsInput:
            Text(ClaudeFormat.status(of: session))
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.trafficRed)
                .lineLimit(1)
        case .done:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 2) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                    Text(ClaudeFormat.shortElapsed(since: session.phaseChangedAt, now: context.date))
                }
                .font(DesignTokens.Fonts.rowMeta)
                .foregroundStyle(DesignTokens.Colors.secondaryText)
            }
        case .working, .idle:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(ClaudeFormat.shortElapsed(since: session.phaseChangedAt, now: context.date))
                    .font(DesignTokens.Fonts.rowMeta)
                    .foregroundStyle(DesignTokens.Colors.secondaryText)
            }
        }
    }

    private var tooltip: String {
        var parts = [session.displayTitle, session.projectName]
        if let host = ClaudeHostApps.displayName(for: session.host) { parts.append(host) }
        if session.isStale { parts.append("no activity for a while") }
        if let error = session.lastError { parts.append("error: \(error)") }
        return parts.joined(separator: " · ") + "\nClick to open the chat"
    }
}
