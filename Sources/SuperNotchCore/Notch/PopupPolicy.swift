import Foundation

// Owner: notch-shell. Signatures FROZEN (SPEC §D.2, §A.6). Pure decision whether an auto-popup is shown, plus
// the pure popup queue the shell's coordinator drives (tested on Linux).

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

    public init(
        settings: AppSettings, isFullscreen: Bool, isExpanded: Bool, isNotchAvailable: Bool,
        frontmostAppBundleID: String?
    ) {
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
        queue.min(by: displayOrder)
    }

    /// Display order: critical before info, then oldest first (ties broken by id for determinism).
    public static func displayOrder(_ lhs: PopupRequest, _ rhs: PopupRequest) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }
}

// MARK: - Popup queue

/// "Request 2 of 3" for a popup among the popups of the same kind (permission cards / session peeks).
public struct NotchPopupPosition: Sendable, Hashable {
    /// 1-based.
    public var index: Int
    public var total: Int

    public init(index: Int, total: Int) {
        self.index = index
        self.total = total
    }
}

/// The pure state behind `NotchViewModel.present/withdraw` (SPEC §A.6):
/// * at most one popup (`current`) is on screen; everything else waits in `queued`;
/// * the same `id` replaces (shown or queued);
/// * 🟢 (`.info`) requests are held back for `debounce` so a 🟢 → 🟡 flip within 0.8 s never pops up;
/// * a 🔴 preempts a 🟢 on screen (the 🟢 is dropped: the Home list still shows it);
/// * `autoDismissAfter` runs while the popup is on screen and the pointer is not over it;
/// * permission cards expire after `permissionTimeout` (the hook gives up then anyway);
/// * queued 🟢 notices go stale after `infoStaleAfter`.
///
/// Every mutating call returns what the screen must do. The owner keeps exactly one timer for
/// `nextDeadline` and calls `tick(context:now:)` when it fires.
public struct NotchPopupQueue: Sendable, Hashable {
    public enum Effect: Sendable, Hashable {
        /// Nothing changes on screen.
        case none
        /// Show this popup (new or updated content). Only when the notch is not expanded.
        case show(PopupRequest)
        /// No popup should be on screen any more (collapse a peek; never touches an expanded notch).
        case hide
    }

    public static let permissionTimeout: TimeInterval = 290
    public static let infoStaleAfter: TimeInterval = 60

    public var debounce: TimeInterval
    /// The popup on screen.
    public private(set) var current: PopupRequest?
    /// When `current` appeared (auto-dismiss clock).
    public private(set) var currentShownAt: Date?
    /// Waiting popups (policy said "queue", or another popup is on screen), unsorted.
    public private(set) var queued: [PopupRequest] = []
    /// 🟢 requests younger than `debounce`.
    public private(set) var debouncing: [PopupRequest] = []
    /// True while the pointer is over the popup: the auto-dismiss clock is paused (restarts on exit).
    public private(set) var isAutoDismissPaused = false

    public init(debounce: TimeInterval = NotchMetrics.popupDebounce) {
        self.debounce = max(debounce, 0)
    }

    /// Waiting popups in display order (critical first, then oldest).
    public var queuedInOrder: [PopupRequest] { queued.sorted(by: PopupPolicy.displayOrder) }

    public var isEmpty: Bool { current == nil && queued.isEmpty && debouncing.isEmpty }

    public func contains(id: String) -> Bool {
        current?.id == id || queued.contains { $0.id == id } || debouncing.contains { $0.id == id }
    }

    /// Position of a popup among the shown + queued popups of the same kind, oldest first.
    public func position(of id: String) -> NotchPopupPosition? {
        var all = queued
        if let current { all.append(current) }
        guard let target = all.first(where: { $0.id == id }) else { return nil }
        let sameKind = all.filter { Self.kind(of: $0) == Self.kind(of: target) }.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id
        }
        guard let index = sameKind.firstIndex(where: { $0.id == id }) else { return nil }
        return NotchPopupPosition(index: index + 1, total: sameKind.count)
    }

    // MARK: Mutations

    public mutating func present(_ request: PopupRequest, context: PopupContext, now: Date) -> Effect {
        let before = current
        queued.removeAll { $0.id == request.id }
        debouncing.removeAll { $0.id == request.id }
        if current?.id == request.id {
            // Replace in place (keeps the auto-dismiss clock) unless the new content is not wanted any more.
            if PopupPolicy.decide(request, context: context) == .suppress {
                clearCurrent()
                advance(context: context, now: now)
            } else {
                current = request
                if request != before { currentShownAt = now }
            }
            return effect(from: before)
        }
        if request.priority == .info, debounce > 0, now < request.createdAt.addingTimeInterval(debounce) {
            debouncing.append(request)
            return .none
        }
        admit(request, context: context, now: now)
        return effect(from: before)
    }

    /// Removes a shown or queued popup (answered, state changed, …). The next waiting popup may show.
    public mutating func withdraw(id: String, context: PopupContext, now: Date) -> Effect {
        let before = current
        queued.removeAll { $0.id == id }
        debouncing.removeAll { $0.id == id }
        if current?.id == id {
            clearCurrent()
            advance(context: context, now: now)
        }
        return effect(from: before)
    }

    /// The user dismissed the popup on screen (hover-leave, click outside, auto-collapse).
    public mutating func dismissCurrent(context: PopupContext, now: Date) -> Effect {
        let before = current
        guard current != nil else { return .none }
        clearCurrent()
        advance(context: context, now: now)
        return effect(from: before)
    }

    /// The user expanded the notch over a popup: a 🔴 goes back to the queue (it returns when the notch
    /// collapses and is still pending); a 🟢 is considered seen and dropped. The caller changes the screen.
    public mutating func requeueCurrent() {
        guard let request = current else { return }
        clearCurrent()
        if request.priority == .critical { queued.append(request) }
    }

    /// Re-applies the policy after the world changed (notch collapsed, fullscreen, frontmost app, settings).
    public mutating func reevaluate(context: PopupContext, now: Date) -> Effect {
        let before = current
        dropExpired(now: now)
        if let request = current {
            switch PopupPolicy.decide(request, context: context) {
            case .suppress:
                clearCurrent()
                advance(context: context, now: now)
            case .queue:
                requeueCurrent()
            case .show:
                break
            }
        } else {
            advance(context: context, now: now)
        }
        return effect(from: before)
    }

    /// Pauses (pointer over the popup) or restarts (pointer left) the auto-dismiss clock.
    public mutating func setAutoDismissPaused(_ paused: Bool, now: Date) {
        guard paused != isAutoDismissPaused else { return }
        isAutoDismissPaused = paused
        if !paused, current != nil { currentShownAt = now }
    }

    /// Processes everything due at `now`: debounced 🟢 requests, auto-dismiss, expiry.
    public mutating func tick(context: PopupContext, now: Date) -> Effect {
        let before = current
        let due = debouncing.filter { now >= $0.createdAt.addingTimeInterval(debounce) }
        if !due.isEmpty {
            debouncing.removeAll { request in due.contains { $0.id == request.id } }
            for request in due { admit(request, context: context, now: now) }
        }
        if let request = current, let shownAt = currentShownAt {
            let autoDismissDue =
                !isAutoDismissPaused
                && request.autoDismissAfter.map { now >= shownAt.addingTimeInterval($0) } == true
            if autoDismissDue || Self.isExpired(request, onScreen: true, now: now) {
                clearCurrent()
            }
        }
        dropExpired(now: now)
        if current == nil { advance(context: context, now: now) }
        return effect(from: before)
    }

    /// The earliest time `tick` has something to do.
    public func nextDeadline() -> Date? {
        var dates = debouncing.map { $0.createdAt.addingTimeInterval(debounce) }
        if let request = current {
            if let after = request.autoDismissAfter, let shownAt = currentShownAt, !isAutoDismissPaused {
                dates.append(shownAt.addingTimeInterval(after))
            }
            if let expiry = Self.expiry(of: request, onScreen: true) { dates.append(expiry) }
        }
        dates.append(contentsOf: queued.compactMap { Self.expiry(of: $0, onScreen: false) })
        return dates.min()
    }

    public mutating func removeAll() {
        clearCurrent()
        queued.removeAll()
        debouncing.removeAll()
    }

    // MARK: Internals

    private mutating func admit(_ request: PopupRequest, context: PopupContext, now: Date) {
        guard !Self.isExpired(request, onScreen: false, now: now) else { return }
        switch PopupPolicy.decide(request, context: context) {
        case .suppress:
            return
        case .queue:
            queued.append(request)
        case .show:
            guard let shown = current else {
                setCurrent(request, now: now)
                return
            }
            if request.priority > shown.priority {
                // 🔴 preempts 🟢. A preempted critical (cannot happen today) would go back to the queue.
                clearCurrent()
                if shown.priority == .critical { queued.append(shown) }
                setCurrent(request, now: now)
            } else {
                queued.append(request)
            }
        }
    }

    /// Shows the best waiting popup the policy allows, dropping the ones it suppresses.
    private mutating func advance(context: PopupContext, now: Date) {
        guard current == nil else { return }
        dropExpired(now: now)
        while let candidate = PopupPolicy.next(from: queued) {
            switch PopupPolicy.decide(candidate, context: context) {
            case .show:
                queued.removeAll { $0.id == candidate.id }
                setCurrent(candidate, now: now)
                return
            case .suppress:
                queued.removeAll { $0.id == candidate.id }
            case .queue:
                return
            }
        }
    }

    private mutating func dropExpired(now: Date) {
        queued.removeAll { Self.isExpired($0, onScreen: false, now: now) }
        if let request = current, Self.isExpired(request, onScreen: true, now: now) { clearCurrent() }
    }

    private mutating func setCurrent(_ request: PopupRequest, now: Date) {
        current = request
        currentShownAt = now
        isAutoDismissPaused = false
    }

    private mutating func clearCurrent() {
        current = nil
        currentShownAt = nil
        isAutoDismissPaused = false
    }

    private func effect(from before: PopupRequest?) -> Effect {
        if current == before { return .none }
        if let current { return .show(current) }
        return .hide
    }

    /// Permission cards always expire (the hook has given up by then). A waiting 🟢 goes stale; one on screen
    /// is governed by its auto-dismiss clock instead (it must not vanish under the pointer).
    private static func expiry(of request: PopupRequest, onScreen: Bool) -> Date? {
        switch request.payload {
        case .claudePermission:
            return request.createdAt.addingTimeInterval(permissionTimeout)
        case .claudeSession:
            guard !onScreen, request.priority == .info else { return nil }
            return request.createdAt.addingTimeInterval(infoStaleAfter)
        }
    }

    private static func isExpired(_ request: PopupRequest, onScreen: Bool, now: Date) -> Bool {
        guard let expiry = expiry(of: request, onScreen: onScreen) else { return false }
        return now >= expiry
    }

    private static func kind(of request: PopupRequest) -> Int {
        switch request.payload {
        case .claudePermission: return 0
        case .claudeSession: return 1
        }
    }
}
