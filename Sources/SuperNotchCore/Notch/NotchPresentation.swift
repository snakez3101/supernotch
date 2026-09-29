import Foundation

// FOUNDATION-OWNED (SPEC §D.2). Presentation + popup contract shared by notch-shell and the feature streams.

public enum NotchTab: String, Sendable, Codable, CaseIterable, Hashable {
    case home
    case shelf
}

public enum PopupPriority: Int, Sendable, Hashable, Comparable {
    /// 🟢 done: focus-aware, suppressed in fullscreen, auto-collapses.
    case info = 0
    /// 🔴 needs input: always shown, even in fullscreen.
    case critical = 1

    public static func < (lhs: PopupPriority, rhs: PopupPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PopupPayload: Sendable, Hashable {
    /// Done / question peek for a session → `ClaudePeekView(sessionID:)`.
    case claudeSession(sessionID: String)
    /// Permission card → `PermissionCardView(requestID:)`.
    case claudePermission(requestID: String)
}

public struct PopupRequest: Sendable, Hashable, Identifiable {
    /// Same id ⇒ the newer request replaces the older one (shown or queued).
    public var id: String
    public var priority: PopupPriority
    public var payload: PopupPayload
    /// Bundle id of the app hosting the session (focus-aware suppression of `.info`).
    public var hostAppBundleID: String?
    /// Auto-dismiss after this many seconds (nil = stays until withdrawn/answered/closed by the user).
    public var autoDismissAfter: TimeInterval?
    public var createdAt: Date

    public init(
        id: String, priority: PopupPriority, payload: PopupPayload, hostAppBundleID: String? = nil,
        autoDismissAfter: TimeInterval? = nil, createdAt: Date
    ) {
        self.id = id
        self.priority = priority
        self.payload = payload
        self.hostAppBundleID = hostAppBundleID
        self.autoDismissAfter = autoDismissAfter
        self.createdAt = createdAt
    }

    /// Canonical popup id for a session peek.
    public static func claudeSessionID(_ sessionID: String) -> String { "claude.session.\(sessionID)" }
    /// Canonical popup id for a permission card.
    public static func claudePermissionID(_ requestID: String) -> String { "claude.permission.\(requestID)" }

    /// Convenience: 🟢 done peek.
    public static func claudeDone(
        sessionID: String, hostAppBundleID: String?, autoDismissAfter: TimeInterval, now: Date
    ) -> PopupRequest {
        PopupRequest(
            id: claudeSessionID(sessionID), priority: .info, payload: .claudeSession(sessionID: sessionID),
            hostAppBundleID: hostAppBundleID, autoDismissAfter: autoDismissAfter, createdAt: now)
    }

    /// Convenience: 🔴 question peek.
    public static func claudeNeedsInput(sessionID: String, hostAppBundleID: String?, now: Date) -> PopupRequest {
        PopupRequest(
            id: claudeSessionID(sessionID), priority: .critical, payload: .claudeSession(sessionID: sessionID),
            hostAppBundleID: hostAppBundleID, autoDismissAfter: nil, createdAt: now)
    }

    /// Convenience: 🔴 permission card.
    public static func claudePermission(requestID: String, hostAppBundleID: String?, now: Date) -> PopupRequest {
        PopupRequest(
            id: claudePermissionID(requestID), priority: .critical,
            payload: .claudePermission(requestID: requestID), hostAppBundleID: hostAppBundleID,
            autoDismissAfter: nil, createdAt: now)
    }
}

public enum NotchPresentation: Sendable, Hashable {
    case closed
    case peek(PopupRequest)
    case expanded(NotchTab)

    public var isClosed: Bool { self == .closed }
    public var isExpanded: Bool {
        if case .expanded = self { return true }
        return false
    }
    public var peekRequest: PopupRequest? {
        if case .peek(let request) = self { return request }
        return nil
    }
}
