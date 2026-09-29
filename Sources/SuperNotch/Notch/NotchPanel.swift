// Owner: notch-shell (SPEC §A.2, §A.4, §F.4 #8/#9).
//
// `NotchPanel`: one fixed-size (NotchMetrics.panelSize), borderless, non-activating, transparent panel above
// the menu bar on every space, including fullscreen spaces. SwiftUI morphs the notch shape inside it; the
// window itself never animates or resizes.
//
// `NotchHostingView`: the SwiftUI host. Hit-testing is limited to the current notch shape, so clicks anywhere
// else in the panel fall through to the menu bar and the windows below; `acceptsFirstMouse` makes the first
// click on a button work without first focusing the panel.
//
// Window configuration follows DynamicNotchKit (MIT) and vibe-notch/claude-island (Apache-2.0,
// `PassThroughHostingView`); the shape-limited hitTest idea is also used by notchi (pattern only).
import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    /// Asked by AppKit whenever the panel could become key. The shell allows it only while the notch is open,
    /// and it only happens on an explicit interaction (click inside, hotkey), never on hover or auto popups.
    var allowsKeyFocus: () -> Bool = { false }
    /// Key status changed (`true` = became key).
    var onKeyStatusChange: ((Bool) -> Void)?
    /// Esc reached the window (no focused control handled it).
    var onCancel: (() -> Void)?

    override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        worksWhenModal = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        allowsToolTipsWhenApplicationIsInactive = true
        appearance = NSAppearance(named: .darkAqua)
    }

    /// The panel deliberately covers the menu bar next to the notch: never let AppKit push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { allowsKeyFocus() }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        onKeyStatusChange?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyStatusChange?(false)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            super.cancelOperation(sender)
        }
    }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// The screen rect that accepts mouse events (the current notch shape), or nil for none.
    var hitRegion: () -> CGRect? = { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window, let region = hitRegion() else { return nil }
        // `point` is in the superview's coordinate system (the window's frame view for the content view).
        let pointInWindow = superview.map { $0.convert(point, to: nil) } ?? point
        let pointOnScreen = window.convertPoint(toScreen: pointInWindow)
        guard region.contains(pointOnScreen) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
