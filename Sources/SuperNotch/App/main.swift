// Owner: FOUNDATION (SPEC §B.1, §G.2).
//
// Entry point. SuperNotch is an accessory app (LSUIElement in Info.plist) at all times: no Dock icon, no menu
// bar and no ⌘-Tab entry, not even while the Settings or onboarding window is open (see AppDelegate).
import AppKit

MainActor.assumeIsolated {
    // `SuperNotch --smoke-test`: CI launch check (SPEC §G.2). Exits by itself with 0 on success.
    if CommandLine.arguments.contains(SmokeTest.argument) {
        SmokeTest.run()
    }

    let application = NSApplication.shared
    // Also covers unbundled launches (`swift run`), where Info.plist's LSUIElement is absent.
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate  // NSApplication.delegate is weak: keep `delegate` alive below.
    withExtendedLifetime(delegate) {
        application.run()
    }
}
