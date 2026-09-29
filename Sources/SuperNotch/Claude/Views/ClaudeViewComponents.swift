// Owner: claude-app. Small building blocks shared by the Claude views: the traffic-light dot, compact
// capsule buttons and text formatting (relative times, percentages, reset times).

import SuperNotchCore
import SwiftUI

/// 🟡 working (subtle pulse) · 🟢 done · 🔴 needs you · ⚪ idle.
/// The pulse is an SF Symbols effect (rendered by Core Animation, no per-frame SwiftUI updates), so a
/// working session can pulse in the closed notch all day without costing energy (SPEC §F.1).
struct ClaudeTrafficDot: View {
    let light: TrafficLight
    var diameter: CGFloat = DesignTokens.Size.rowDot
    /// Pulse 🟡 / 🔴 (off for stale sessions and in static contexts).
    var isAnimated = true
    /// Dim the dot (e.g. a stale working session).
    var isDimmed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pulses: Bool {
        isAnimated && !reduceMotion && (light == .yellow || light == .red)
    }

    var body: some View {
        // Sized with the font, not `.resizable()`: symbol effects need a real symbol image.
        Image(systemName: "circle.fill")
            .font(.system(size: diameter, weight: .regular))
            .foregroundStyle(DesignTokens.Colors.trafficLight(light))
            .symbolEffect(.pulse, options: .repeating, isActive: pulses)
            .opacity(isDimmed ? 0.45 : 1)
            .frame(width: diameter, height: diameter)
            .accessibilityLabel(ClaudeFormat.accessibilityLabel(for: light))
    }
}

/// Compact capsule button used on the permission card and in the Home column.
struct ClaudeCapsuleButtonStyle: ButtonStyle {
    enum Kind {
        case neutral
        case primary
        case danger
    }

    var kind: Kind = .neutral

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignTokens.Fonts.bodyEmphasized)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.m + 2)
            .frame(height: 22)
            .foregroundStyle(foreground)
            .background(background.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .neutral: return DesignTokens.Colors.primaryText
        case .primary: return .black
        case .danger: return .white
        }
    }

    private var background: Color {
        switch kind {
        case .neutral: return DesignTokens.Colors.controlFill
        case .primary: return DesignTokens.Colors.primaryText
        case .danger: return DesignTokens.Colors.danger
        }
    }
}

/// Text formatting for the Claude views. Pure, so it can be used anywhere.
nonisolated enum ClaudeFormat {
    /// "/Users/me/.claude" → "~/.claude".
    static func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, home != "/", path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// "now", "2m", "1h", "3d".
    static func shortElapsed(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// "62 %".
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded())) %"
    }

    /// "in 2 h 14 min", "in 5 min", "in 3 d".
    static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(max(minutes, 1)) min" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0 ? "in \(days) d" : "in \(days) d \(restHours) h"
    }

    /// "Resets in 2 h 14 min (14:30)".
    static func resetDescription(_ date: Date?, now: Date) -> String {
        guard let date else { return "Reset time unknown" }
        let clock = date.formatted(date: .omitted, time: .shortened)
        if date.timeIntervalSince(now) > 86_400 {
            let day = date.formatted(.dateTime.weekday(.abbreviated))
            return "Resets \(countdown(to: date, now: now)) (\(day) \(clock))"
        }
        return "Resets \(countdown(to: date, now: now)) (\(clock))"
    }

    /// "updated 3 min ago".
    static func updatedDescription(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "updated just now" }
        if seconds < 3_600 { return "updated \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "updated \(Int(seconds / 3_600)) h ago" }
        return "updated \(Int(seconds / 86_400)) d ago"
    }

    static func accessibilityLabel(for light: TrafficLight) -> String {
        switch light {
        case .red: return "Needs you"
        case .yellow: return "Working"
        case .green: return "Done"
        case .grey: return "Idle"
        }
    }

    /// Short status for a row or peek.
    static func status(of session: Session) -> String {
        switch session.phase {
        case .needsInput(.permission): return "Approve"
        case .needsInput(.question): return "Question"
        case .needsInput(.other): return "Waiting"
        case .working: return session.isStale ? "Quiet" : "Working"
        case .done: return session.hasError ? "Stopped" : "Done"
        case .idle: return "Idle"
        }
    }

    /// SF Symbol for a tool on the permission card.
    static func symbol(forTool toolName: String) -> String {
        switch toolName {
        case "Bash", "PowerShell": return "terminal"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Read": return "doc.text"
        case "WebFetch", "WebSearch": return "globe"
        case "ExitPlanMode": return "list.bullet.clipboard"
        default: return toolName.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    /// "mcp__github__create_issue" → "github · create_issue".
    static func toolDisplayName(_ toolName: String) -> String {
        guard toolName.hasPrefix("mcp__") else { return toolName }
        let parts = toolName.dropFirst(5).split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return toolName }
        let server = parts[0]
        let tool = parts[1].hasPrefix("_") ? parts[1].dropFirst() : parts[1]
        return "\(server) · \(tool)"
    }
}
