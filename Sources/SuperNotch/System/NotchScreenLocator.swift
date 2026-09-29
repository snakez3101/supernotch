// Owner: notch-shell (SPEC §A.9).
//
// Finds the built-in display with a notch. External displays never get a notch (REQUIREMENTS); in clamshell
// mode, without a built-in display, or in macOS 27's "below the notch" mode (no safe-area inset, no auxiliary
// areas) there is no notch and the app stays invisible.
import AppKit
import SuperNotchCore

struct NotchScreenInfo: Equatable {
    let displayID: CGDirectDisplayID
    let geometry: NotchGeometry
}

enum NotchScreenLocator {
    private static let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")

    /// The built-in notch display, or nil.
    static func builtInNotchScreen() -> NotchScreenInfo? {
        for screen in NSScreen.screens {
            guard let displayID = displayID(of: screen), CGDisplayIsBuiltin(displayID) != 0 else { continue }
            let geometry = NotchGeometry(
                screenFrame: screen.frame,
                safeAreaTop: screen.safeAreaInsets.top,
                auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
                auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width)
            guard let geometry else {
                Log.system.info("Built-in display has no notch (or below-notch mode): staying invisible")
                return nil
            }
            return NotchScreenInfo(displayID: displayID, geometry: geometry)
        }
        return nil
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}
