import Foundation

// Owner: notch-shell. Signatures FROZEN (SPEC §D.2, §A.6). Pure decision whether an auto-popup is shown.

public struct PopupContext: Sendable, Hashable {
    public var isFullscreen: Bool
    /// The user has the notch expanded (popups queue instead of interrupting).
    public var isExpanded: Bool
    /// False when there is no built-in notch display (clamshell / external only).
    public var isNotchAvailable: Bool
    public var frontmostAppBundleID: String?
    public var popupsForNeedsInput: Bool
    public var popupsForDone: Bool
    public var skipDoneWhenHostFrontmost: Bool
    public var hideInFullscreen: Bool

    public init(
        isFullscreen: Bool = false, isExpanded: Bool = false, isNotchAvailable: Bool = true,
        frontmostAppBundleID: String? = nil, popupsForNeedsInput: Bool = true, popupsForDone: Bool = true,
        skipDoneWhenHostFrontmost: Bool = true, hideInFullscreen: Bool = true
    ) {
        self.isFullscreen = isFullscreen
        self.isExpanded = isExpanded
        self.isNotchAvailable = isNotchAvailable
        self.frontmostAppBundleID = frontmostAppBundleID
        self.popupsForNeedsInput = popupsForNeedsInput
        self.popupsForDone = popupsForDone
        self.skipDoneWhenHostFrontmost = skipDoneWhenHostFrontmost
        self.hideInFullscreen = hideInFullscreen
    }

    public init(settings: AppSettings, isFullscreen: Bool, isExpanded: Bool, isNotchAvailable: Bool,
        frontmostAppBundleID: String?)
    {
        self.init(
            isFullscreen: isFullscreen, isExpanded: isExpanded, isNotchAvailable: isNotchAvailable,
            frontmostAppBundleID: frontmostAppBundleID, popupsForNeedsInput: settings.popupOnNeedsInput,
            popupsForDone: settings.popupOnDone, skipDoneWhenHostFrontmost: settings.skipDoneWhenHostFrontmost,
            hideInFullscreen: settings.hideInFullscreen)
    }
}

public enum PopupDecision: Sendable, Hashable {
    case show
    /// Keep it and show when the user collapses the notch (still relevant then).
    case queue
    case suppress
}

public enum PopupPolicy {
    public static func decide(_ request: PopupRequest, context: PopupContext) -> PopupDecision {
        guard context.isNotchAvailable else { return .suppress }
        switch request.priority {
        case .critical:
            guard context.popupsForNeedsInput else { return .suppress }
            // Red always pops, including fullscreen (REQUIREMENTS). While expanded the list already shows it.
            return context.isExpanded ? .queue : .show
        case .info:
            guard context.popupsForDone else { return .suppress }
            if context.isFullscreen && context.hideInFullscreen { return .suppress }
            if context.skipDoneWhenHostFrontmost, let host = request.hostAppBundleID,
                host == context.frontmostAppBundleID
            {
                return .suppress
            }
            // A done notice is stale once the user has looked at the expanded notch.
            return context.isExpanded ? .suppress : .show
        }
    }

    /// Which of several shown/queued requests should be on screen: critical first, then oldest.
    public static func next(from queue: [PopupRequest]) -> PopupRequest? {
        queue.min { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.createdAt < rhs.createdAt
        }
    }
}
