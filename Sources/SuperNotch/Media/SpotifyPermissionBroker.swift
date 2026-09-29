// Owner: media stream. Automation (TCC) permission for Spotify, on queues of its own (never the AppleScript queue).
//
//  * Asking: ONE real, harmless Apple Event (`get name` of Spotify). A real event reliably makes tccd show
//    "SuperNotch wants to control Spotify"; `AEDeterminePermissionToAutomateTarget(askUser: true)` can hang
//    without ever showing it (Apple DTS, developer.apple.com/forums/thread/666528, FB8919870).
//  * Silent status: `AEDeterminePermissionToAutomateTarget(askUser: false)`, never prompts.
//  * Reset: `/usr/bin/tccutil reset AppleEvents <our bundle id>`.
// Every call is raced against a timeout (`MediaBlockingCallRunner`), so a hung call cannot freeze a button or
// the AppleScript queue, and a second click joins the call in flight instead of stacking another one.
import AppKit
import ApplicationServices
import CoreServices
import Foundation
import SuperNotchCore
import os

nonisolated final class SpotifyPermissionBroker: @unchecked Sendable {
    private let askRunner = MediaBlockingCallRunner(
        label: "io.github.snakez3101.supernotch.media.permission.ask", qos: .userInitiated)
    private let checkRunner = MediaBlockingCallRunner(
        label: "io.github.snakez3101.supernotch.media.permission.check", qos: .utility)
    private let resetRunner = MediaBlockingCallRunner(
        label: "io.github.snakez3101.supernotch.media.permission.reset", qos: .utility)

    /// Silent check (no prompt): the raw `AEDeterminePermissionToAutomateTarget` status, or `.timedOut` after
    /// `MediaPermissionTimeouts.silentCheck`.
    func check() async -> MediaPermissionCallResult {
        await checkRunner.run(
            timeout: MediaPermissionTimeouts.silentCheck,
            work: { SpotifyPermissionBroker.determinePermissionSilently() })
    }

    /// Sends the probe event, which raises the system dialog when no decision is stored. Returns its status, or
    /// `.timedOut` after `MediaPermissionTimeouts.ask`; a later answer goes to `late`.
    func ask(late: @escaping @Sendable (Int32) -> Void) async -> MediaPermissionCallResult {
        await askRunner.run(
            timeout: MediaPermissionTimeouts.ask, work: { SpotifyPermissionBroker.sendProbeEvent() }, late: late)
    }

    /// `tccutil reset AppleEvents <bundleID>`. True when it exited with status 0.
    func resetAppleEvents(bundleID: String) async -> Bool {
        let result = await resetRunner.run(
            timeout: MediaPermissionTimeouts.reset,
            work: { SpotifyPermissionBroker.runTCCUtilReset(bundleID: bundleID) })
        switch result {
        case .status(let status):
            return status == 0
        case .timedOut:
            Log.media.error("tccutil reset did not finish within \(MediaPermissionTimeouts.reset, privacy: .public) s")
            return false
        }
    }

    // MARK: Blocking work (runs on the runners' queues only)

    private static func determinePermissionSilently() -> Int32 {
        guard SpotifyApp.isRunning else { return MediaAppleEventStatus.processNotFound }
        let target = NSAppleEventDescriptor(bundleIdentifier: SpotifyApp.bundleID)
        guard let targetDescriptor = target.aeDesc else { return MediaAppleEventStatus.processNotFound }
        let status = withExtendedLifetime(target) {
            AEDeterminePermissionToAutomateTarget(
                targetDescriptor, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        }
        return Int32(status)
    }

    /// `get name` of Spotify as a raw Apple Event. Never launches Spotify (checked first; the target is addressed
    /// by bundle id, and a get-data event is not an open/launch event). Returns 0 on success, otherwise the
    /// thrown `OSStatus` or the reply's error number.
    private static func sendProbeEvent() -> Int32 {
        guard SpotifyApp.isRunning else { return MediaAppleEventStatus.processNotFound }
        typealias Codes = SpotifyPermissionProbe
        let target = NSAppleEventDescriptor(bundleIdentifier: SpotifyApp.bundleID)
        let event = NSAppleEventDescriptor(
            eventClass: Codes.eventClass, eventID: Codes.eventID, targetDescriptor: target, returnID: -1,
            transactionID: 0)
        // Direct object: property 'pnam' of the application (null container).
        if let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: Codes.typeObjectSpecifier) {
            specifier.setDescriptor(
                NSAppleEventDescriptor(typeCode: Codes.classProperty), forKeyword: Codes.keyDesiredClass)
            specifier.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: Codes.keyContainer)
            specifier.setDescriptor(NSAppleEventDescriptor(enumCode: Codes.formPropertyID), forKeyword: Codes.keyForm)
            specifier.setDescriptor(NSAppleEventDescriptor(typeCode: Codes.propertyName), forKeyword: Codes.keyData)
            event.setParam(specifier, forKeyword: Codes.keyDirectObject)
        } else {
            // Still a real event (TCC checks the sender, not the payload); Spotify just answers with an error.
            Log.media.error("Automation probe: object specifier coercion failed; sending the event without it")
        }
        do {
            let reply = try event.sendEvent(
                options: [.waitForReply, .canInteract], timeout: MediaPermissionTimeouts.appleEvent)
            let replyError = reply.paramDescriptor(forKeyword: Codes.keyErrorNumber)?.int32Value ?? 0
            Log.media.info("Automation probe reply: error number \(replyError, privacy: .public)")
            return replyError
        } catch {
            let nsError = error as NSError
            Log.media.info(
                "Automation probe failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
            return Int32(truncatingIfNeeded: nsError.code)
        }
    }

    private static func runTCCUtilReset(bundleID: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MediaPermissionReset.executablePath)
        process.arguments = MediaPermissionReset.arguments(bundleID: bundleID)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            Log.media.error("tccutil could not start: \(error.localizedDescription, privacy: .public)")
            return -1
        }
        // Read before waiting: a full pipe would otherwise block tccutil forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = process.terminationStatus
        if status == 0 {
            Log.media.info("tccutil reset AppleEvents succeeded: \(output, privacy: .public)")
        } else {
            Log.media.error(
                "tccutil reset AppleEvents exited with \(status, privacy: .public): \(output, privacy: .public)")
        }
        return status
    }
}
