// Owner: notch-shell (SPEC §A.8).
//
// Is the frontmost app fullscreen on the notch display? Public APIs only: the on-screen window list
// (`CGWindowListCopyWindowInfo`; owner pid, layer and bounds need no Screen Recording permission) fed into the
// pure, unit-tested `NotchFullscreenHeuristic` (Core). Called only on space/app/screen changes, never polled.
import AppKit
import SuperNotchCore

enum NotchFullscreenDetector {
    static func isFullscreen(on displayID: CGDirectDisplayID, notchHeight: CGFloat) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        let frontmostPID = frontmost.processIdentifier
        // Our own windows (Settings, onboarding) are never "fullscreen apps" for this purpose.
        guard frontmostPID != ProcessInfo.processInfo.processIdentifier else { return false }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        var windows: [NotchWindowSample] = []
        windows.reserveCapacity(list.count)
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }
            windows.append(NotchWindowSample(ownerPID: pid, layer: layer, bounds: bounds))
        }
        // CGDisplayBounds is already in Quartz global coordinates (origin top-left of the primary display).
        let screenFrame = CGDisplayBounds(displayID)
        return NotchFullscreenHeuristic.isFullscreen(
            windows: windows, frontmostPID: frontmostPID, screenFrame: screenFrame, notchHeight: notchHeight)
    }
}
