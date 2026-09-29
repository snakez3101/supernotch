// Owner: claude-app. Right column of the Home tab (SPEC §A.5, §D.10): about 290 × 142 pt.
//
//   [inline permission card, if one is waiting]    ← while expanded, 🔴 popups are queued; answer here
//   ● Fix login bug        supernotch   2m         ← rows 26 pt, max 4 visible, scroll
//   ● Refactor parser      app          now
//   5h ━━━━━━━──── 62 %                             ← UsageBarsView at the bottom (drawn here, not by Home)
//   7d ━━━─────── 31 %

import SuperNotchCore
import SwiftUI

struct ClaudeHomeSection: View {
    @Environment(ClaudeSessionsModel.self) private var claude
    @Environment(NotchViewModel.self) private var notch

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            if let request = claude.permissions.first {
                PermissionCardView(requestID: request.id, style: .inline)
                    .transition(.opacity)
            }
            if claude.sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
            UsageBarsView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(DesignTokens.Motion.hover, value: claude.permissions.first?.id)
    }

    private var sessionList: some View {
        let rowHeight = NotchMetrics.claudeRowHeight
        let visibleRows = min(claude.sessions.count, NotchMetrics.claudeVisibleRows)
        return ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(claude.sessions) { session in
                    SessionRowView(session: session) {
                        claude.focus(sessionID: session.id)
                        notch.close()
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: rowHeight * CGFloat(visibleRows))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.s) {
                ClaudeTrafficDot(light: .grey, isAnimated: false)
                Text("No Claude sessions")
                    .font(DesignTokens.Fonts.bodyEmphasized)
                    .foregroundStyle(DesignTokens.Colors.secondaryText)
            }
            if let hint = setupHint {
                Button {
                    notch.openSettings()
                } label: {
                    Text(hint)
                        .font(DesignTokens.Fonts.caption)
                        .foregroundStyle(DesignTokens.Colors.accent)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            } else {
                Text("Start Claude Code in a terminal or the Claude app.")
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.s)
        .padding(.top, DesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Points at Settings when sessions cannot show up.
    private var setupHint: String? {
        if claude.socketError != nil { return "Session tracking is unavailable. Open Settings…" }
        switch claude.hookStatus {
        case .notInstalled: return "Install the Claude Code hooks in Settings…"
        case .needsRepair: return "The Claude Code hooks need a repair. Open Settings…"
        case .failed: return "Claude Code settings could not be read. Open Settings…"
        case .unknown, .installed: return nil
        }
    }
}
