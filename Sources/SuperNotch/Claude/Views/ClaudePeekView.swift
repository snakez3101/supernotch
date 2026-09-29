// Owner: claude-app. Session peek (SPEC §A.6): 🟢 done (start of the last answer) or 🔴 question.
// Content area ≈ 392 × 50 pt below the notch band. A click jumps to the chat (SPEC §D.8).
//
//   ● Fix login bug · supernotch                         Done · iTerm2
//     All tests pass. I refactored the parser and added…

import SuperNotchCore
import SwiftUI

struct ClaudePeekView: View {
    let sessionID: String

    @Environment(ClaudeSessionsModel.self) private var claude
    @Environment(NotchViewModel.self) private var notch

    @State private var isHovering = false

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    var body: some View {
        if let session = claude.session(id: sessionID) {
            content(for: session)
        } else {
            // Session ended meanwhile (the popup is withdrawn by the model); render nothing.
            Color.clear
        }
    }

    private func content(for session: Session) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.m) {
            ClaudeTrafficDot(light: session.trafficLight, diameter: 9)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.xs + 1) {
                    Text(session.displayTitle)
                        .font(DesignTokens.Fonts.title)
                        .foregroundStyle(DesignTokens.Colors.primaryText)
                        .lineLimit(1)
                    Text(session.projectName)
                        .font(DesignTokens.Fonts.caption)
                        .foregroundStyle(DesignTokens.Colors.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DesignTokens.Spacing.xs)
                    Text(statusLine(for: session))
                        .font(DesignTokens.Fonts.caption)
                        .foregroundStyle(statusColor(for: session))
                        .lineLimit(1)
                }
                Text(message(for: session))
                    .font(DesignTokens.Fonts.body)
                    .foregroundStyle(DesignTokens.Colors.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
                .fill(isHovering ? DesignTokens.Colors.hoverFill : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.hover) { isHovering = hovering }
        }
        .onTapGesture {
            claude.focus(sessionID: session.id)
            notch.close()
        }
        .help("Open the chat")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the chat")
    }

    private func statusLine(for session: Session) -> String {
        let status = ClaudeFormat.status(of: session)
        guard let host = ClaudeHostApps.displayName(for: session.host) else { return status }
        return "\(status) · \(host)"
    }

    private func statusColor(for session: Session) -> Color {
        switch session.trafficLight {
        case .red: return DesignTokens.Colors.trafficRed
        case .green: return session.hasError ? DesignTokens.Colors.warningOrange : DesignTokens.Colors.trafficGreen
        case .yellow: return DesignTokens.Colors.trafficYellow
        case .grey: return DesignTokens.Colors.secondaryText
        }
    }

    private func message(for session: Session) -> String {
        switch session.phase {
        case .needsInput(.question):
            return "Claude has a question for you. Click to open the chat."
        case .needsInput(.permission):
            return "Claude is waiting for your approval. Click to open the chat."
        case .needsInput(.other):
            return "Claude is waiting for you. Click to open the chat."
        case .done:
            if let error = session.lastError { return "Stopped: \(error)" }
            if let preview = session.lastAssistantPreview, !preview.isEmpty { return preview }
            return "Finished. Click to open the chat."
        case .working:
            return "Working…"
        case .idle:
            return "Ready for your next prompt."
        }
    }
}
