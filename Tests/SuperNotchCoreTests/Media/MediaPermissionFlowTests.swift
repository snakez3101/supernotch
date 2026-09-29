// Owner: media. Automation connect flow: status mapping, "never downgrade denied", the request state machine,
// the presentation of every state, timeouts / joining of blocking calls, launch readiness and the tccutil reset.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("MediaPermissionFlow")
struct MediaPermissionFlowTests {
    // MARK: Status mapping

    @Test func askOutcomeMapping() {
        #expect(MediaPermissionAskOutcome(.status(0)) == .granted)
        #expect(MediaPermissionAskOutcome(.status(-1743)) == .denied)
        #expect(MediaPermissionAskOutcome(.status(-600)) == .notRunning)
        #expect(MediaPermissionAskOutcome(.status(-609)) == .notRunning)
        #expect(MediaPermissionAskOutcome(.status(-1712)) == .problem(.noAnswer))
        #expect(MediaPermissionAskOutcome(.timedOut) == .problem(.noAnswer))
        #expect(MediaPermissionAskOutcome(.status(-1744)) == .problem(.couldNotAsk(status: -1744)))
        #expect(MediaPermissionAskOutcome(.status(-1713)) == .problem(.couldNotAsk(status: -1713)))
        #expect(MediaPermissionAskOutcome(.status(-1708)) == .problem(.couldNotAsk(status: -1708)))
        #expect(MediaPermissionAskOutcome(.status(-50)) == .problem(.couldNotAsk(status: -50)))
    }

    @Test func silentMergeBasics() {
        for current in MediaAutomationPermission.allCases {
            #expect(MediaAutomationPermission.merging(silent: .status(0), into: current) == .granted)
            #expect(MediaAutomationPermission.merging(silent: .status(-1743), into: current) == .denied)
            #expect(MediaAutomationPermission.merging(silent: .status(-600), into: current) == .notRunning)
            #expect(MediaAutomationPermission.merging(silent: .status(-609), into: current) == .notRunning)
            // No answer or an unexpected status says nothing reliable.
            #expect(MediaAutomationPermission.merging(silent: .timedOut, into: current) == current)
            #expect(MediaAutomationPermission.merging(silent: .status(-50), into: current) == current)
        }
    }

    @Test func silentConsentNeededNeverDowngradesDenied() {
        #expect(MediaAutomationPermission.merging(silent: .status(-1744), into: .denied) == .denied)
        #expect(MediaAutomationPermission.merging(silent: .status(-1713), into: .denied) == .denied)
        #expect(MediaAutomationPermission.merging(silent: .status(-1744), into: .unknown) == .unknown)
        #expect(MediaAutomationPermission.merging(silent: .status(-1744), into: .notRunning) == .unknown)
        // A grant that was removed (e.g. reset in Terminal) really is undecided again.
        #expect(MediaAutomationPermission.merging(silent: .status(-1744), into: .granted) == .unknown)
    }

    // MARK: State machine

    @Test func happyPath() {
        var flow = MediaPermissionFlow()
        let result1 = flow.beginWaitingForSpotify()
        #expect(result1)
        #expect(flow.request == .waitingForSpotify)
        let result2 = flow.beginAsking()
        #expect(result2)
        #expect(flow.request == .asking)
        let result3 = flow.finishAsking(.status(0))
        #expect(result3 == .granted)
        #expect(flow == MediaPermissionFlow(permission: .granted, request: .idle))
    }

    @Test func busyStatesRejectNewRequests() {
        var flow = MediaPermissionFlow()
        flow.beginWaitingForSpotify()
        let result4 = flow.beginWaitingForSpotify()
        #expect(!result4)
        let result5 = flow.beginResetting()
        #expect(!result5)
        flow.beginAsking()
        let result6 = flow.beginWaitingForSpotify()
        #expect(!result6)
        let result7 = flow.beginAsking()
        #expect(!result7)
        let result8 = flow.beginResetting()
        #expect(!result8)
        #expect(flow.request == .asking)

        var resetting = MediaPermissionFlow(permission: .denied)
        let result9 = resetting.beginResetting()
        #expect(result9)
        let result10 = resetting.beginAsking()
        #expect(!result10)
        let result11 = resetting.beginWaitingForSpotify()
        #expect(!result11)
    }

    @Test func timeoutFailsVisiblyAndTheButtonWorksAgain() {
        var flow = MediaPermissionFlow()
        flow.beginWaitingForSpotify()
        flow.beginAsking()
        let result12 = flow.finishAsking(.timedOut)
        #expect(result12 == .problem(.noAnswer))
        #expect(flow.request == .failed(.noAnswer))
        #expect(flow.permission == .unknown)
        // "Try Again" is never dead.
        let result13 = flow.beginWaitingForSpotify()
        #expect(result13)
        let result14 = flow.beginAsking()
        #expect(result14)
        let result15 = flow.finishAsking(.status(-1744))
        #expect(result15 == .problem(.couldNotAsk(status: -1744)))
        #expect(flow.request == .failed(.couldNotAsk(status: -1744)))
        let result16 = flow.beginResetting()
        #expect(result16)
    }

    @Test func lateAnswerAfterTimeout() {
        var flow = MediaPermissionFlow()
        flow.beginWaitingForSpotify()
        flow.beginAsking()
        flow.finishAsking(.timedOut)
        flow.applyLateAnswer(-1712)
        #expect(flow.request == .failed(.noAnswer))
        flow.applyLateAnswer(-1744)
        #expect(flow.request == .failed(.noAnswer))
        flow.applyLateAnswer(0)
        #expect(flow == MediaPermissionFlow(permission: .granted, request: .idle))

        var denied = MediaPermissionFlow()
        denied.beginAsking()
        denied.finishAsking(.timedOut)
        denied.applyLateAnswer(-1743)
        #expect(denied == MediaPermissionFlow(permission: .denied, request: .idle))
    }

    @Test func lateAnswerDoesNotEndANewRequest() {
        var flow = MediaPermissionFlow()
        flow.beginAsking()
        flow.finishAsking(.timedOut)
        flow.beginWaitingForSpotify()
        flow.beginAsking()
        flow.applyLateAnswer(0)
        #expect(flow.permission == .granted)
        #expect(flow.request == .asking)
        let result17 = flow.finishAsking(.status(0))
        #expect(result17 == .granted)
        #expect(flow.request == .idle)
    }

    @Test func deniedSurvivesSilentConsentNeeded() {
        var flow = MediaPermissionFlow()
        flow.beginAsking()
        flow.finishAsking(.status(-1743))
        #expect(flow == MediaPermissionFlow(permission: .denied, request: .idle))
        flow.applyObserved(.status(-1744))
        #expect(flow.permission == .denied)
        flow.applyObserved(.timedOut)
        #expect(flow.permission == .denied)
        flow.applyObserved(.status(0))  // switched on in System Settings
        #expect(flow.permission == .granted)
    }

    @Test func silentDecisionEndsAFailedRequest() {
        var flow = MediaPermissionFlow()
        flow.beginAsking()
        flow.finishAsking(.timedOut)
        flow.applyObserved(.status(-1744))
        #expect(flow.request == .failed(.noAnswer))
        flow.applyObserved(.status(0))
        #expect(flow == MediaPermissionFlow(permission: .granted, request: .idle))

        var denied = MediaPermissionFlow()
        denied.beginAsking()
        denied.finishAsking(.status(-1744))
        denied.applyObserved(.status(-1743))
        #expect(denied == MediaPermissionFlow(permission: .denied, request: .idle))
    }

    @Test func keptDenialDoesNotHideAFailedRequest() {
        // Denied before; "Try Again" hangs; the follow-up silent check says -1744 (kept as denied).
        var flow = MediaPermissionFlow(permission: .denied)
        flow.beginWaitingForSpotify()
        flow.beginAsking()
        flow.finishAsking(.timedOut)
        #expect(flow == MediaPermissionFlow(permission: .denied, request: .failed(.noAnswer)))
        flow.applyObserved(.status(-1744))
        flow.applyObserved(.timedOut)
        flow.applyObserved(.status(-50))
        #expect(flow == MediaPermissionFlow(permission: .denied, request: .failed(.noAnswer)))
        #expect(
            MediaPermissionPresentation(permission: flow.permission, request: flow.request, resetCommand: "x").title
                == "macOS didn\u{2019}t answer")
        flow.applyObserved(.status(-1743))
        #expect(flow == MediaPermissionFlow(permission: .denied, request: .idle))
    }

    @Test func resetSucceeds() {
        var flow = MediaPermissionFlow(permission: .denied)
        let result18 = flow.beginResetting()
        #expect(result18)
        #expect(flow.request == .resetting)
        flow.finishResetting(succeeded: true)
        #expect(flow == MediaPermissionFlow(permission: .unknown, request: .idle))
        let result19 = flow.beginWaitingForSpotify()
        #expect(result19)
    }

    @Test func resetFailsAndStaysVisibleWhileDenied() {
        var flow = MediaPermissionFlow(permission: .denied)
        flow.beginResetting()
        flow.finishResetting(succeeded: false)
        #expect(flow == MediaPermissionFlow(permission: .denied, request: .failed(.resetFailed)))
        flow.applyObserved(.status(-1743))
        #expect(flow.request == .failed(.resetFailed))
        flow.applyObserved(.status(-1744))
        #expect(flow.permission == .denied)
        flow.applyObserved(.status(0))
        #expect(flow == MediaPermissionFlow(permission: .granted, request: .idle))
    }

    @Test func finishResettingIgnoredWhenNotResetting() {
        var flow = MediaPermissionFlow(permission: .denied)
        flow.finishResetting(succeeded: true)
        #expect(flow == MediaPermissionFlow(permission: .denied, request: .idle))
    }

    @Test func cancelledRequestKeepsOnlyADecision() {
        var flow = MediaPermissionFlow()
        flow.beginAsking()
        flow.cancelRequest()
        let result20 = flow.finishAsking(.timedOut)
        #expect(result20 == .problem(.noAnswer))
        #expect(flow == MediaPermissionFlow(permission: .unknown, request: .idle))
        flow.beginAsking()
        flow.cancelRequest()
        flow.finishAsking(.status(-1743))
        #expect(flow == MediaPermissionFlow(permission: .denied, request: .idle))
    }

    @Test func spotifyRunningTransitions() {
        var flow = MediaPermissionFlow()
        flow.spotifyDidStop()
        #expect(flow.permission == .notRunning)
        let result21 = flow.beginWaitingForSpotify()
        #expect(result21)
        flow.spotifyDidStop()
        #expect(flow.request == .waitingForSpotify)  // we launched it: keep waiting
        flow.spotifyDidStart()
        #expect(flow.permission == .unknown)
        flow.cancelWaiting()
        #expect(flow.request == .idle)

        var granted = MediaPermissionFlow(permission: .granted)
        granted.spotifyDidStart()
        #expect(granted.permission == .granted)

        var quitWhileAsking = MediaPermissionFlow()
        quitWhileAsking.beginAsking()
        let result22 = quitWhileAsking.finishAsking(.status(-609))
        #expect(result22 == .notRunning)
        #expect(quitWhileAsking == MediaPermissionFlow(permission: .notRunning, request: .idle))
    }

    @Test func cancelWaitingOnlyAffectsWaiting() {
        var flow = MediaPermissionFlow()
        flow.beginAsking()
        flow.cancelWaiting()
        #expect(flow.request == .asking)
    }

    // MARK: Presentation

    private static let command = "tccutil reset AppleEvents io.github.snakez3101.supernotch"

    private static func present(_ permission: MediaAutomationPermission, _ request: MediaPermissionRequestState)
        -> MediaPermissionPresentation
    {
        MediaPermissionPresentation(permission: permission, request: request, resetCommand: command)
    }

    @Test func presentationActions() {
        #expect(Self.present(.unknown, .idle).actions == [.allow])
        #expect(Self.present(.notRunning, .idle).actions == [.openSpotifyAndAllow])
        #expect(Self.present(.denied, .idle).actions == [.openSystemSettings, .resetAndAskAgain, .checkAgain])
        #expect(Self.present(.unknown, .failed(.noAnswer)).actions == [.tryAgain, .resetAndAskAgain, .openSystemSettings])
        #expect(
            Self.present(.unknown, .failed(.couldNotAsk(status: -1744))).actions
                == [.tryAgain, .resetAndAskAgain, .openSystemSettings])
        #expect(
            Self.present(.denied, .failed(.resetFailed)).actions == [.copyResetCommand, .tryAgain, .openSystemSettings])
        #expect(Self.present(.granted, .idle).actions.isEmpty)
    }

    @Test func presentationPrecedence() {
        #expect(Self.present(.denied, .asking).tone == .busy)
        #expect(Self.present(.notRunning, .waitingForSpotify).tone == .busy)
        #expect(Self.present(.denied, .resetting).tone == .busy)
        #expect(Self.present(.granted, .failed(.noAnswer)).tone == .allowed)
        #expect(Self.present(.notRunning, .failed(.noAnswer)).tone == .inactive)
        #expect(Self.present(.denied, .failed(.noAnswer)).title == "macOS didn\u{2019}t answer")
        #expect(Self.present(.denied, .idle).tone == .blocked)
        #expect(Self.present(.unknown, .idle).tone == .attention)
    }

    @Test func presentationDetails() {
        #expect(Self.present(.denied, .failed(.resetFailed)).terminalCommand == Self.command)
        #expect(Self.present(.denied, .idle).terminalCommand == nil)
        #expect(Self.present(.unknown, .failed(.couldNotAsk(status: -1744))).detail?.contains("-1744") == true)
        #expect(Self.present(.unknown, .asking).detail?.contains("SuperNotch wants to control Spotify") == true)
    }

    @Test func everyStateHasAWayOut() {
        let requests: [MediaPermissionRequestState] = [
            .idle, .waitingForSpotify, .asking, .resetting, .failed(.noAnswer), .failed(.couldNotAsk(status: -1744)),
            .failed(.resetFailed),
        ]
        for permission in MediaAutomationPermission.allCases {
            for request in requests {
                let presentation = Self.present(permission, request)
                if request.isBusy {
                    #expect(presentation.isBusy && presentation.actions.isEmpty)
                } else if permission != .granted {
                    #expect(!presentation.actions.isEmpty, "\(permission) \(request)")
                }
                #expect(!presentation.title.isEmpty && !presentation.status.isEmpty)
                #expect(presentation.title.count <= 26, "\(presentation.title)")
                #expect((presentation.compactDetail?.count ?? 0) <= 64, "\(presentation.compactDetail ?? "")")
                #expect(Set(presentation.actions).count == presentation.actions.count)
            }
        }
    }

    @Test func actionTitles() {
        for action in MediaPermissionAction.allCases {
            #expect(!action.title.isEmpty)
            #expect(action.shortTitle.count <= 13)
        }
        #expect(MediaPermissionAction.allow.title == "Allow Access to Spotify")
        #expect(MediaPermissionAction.resetAndAskAgain.title == "Reset & Ask Again")
    }

    // MARK: Readiness, reset, probe codes

    @Test func launchReadiness() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        typealias R = SpotifyLaunchReadiness
        #expect(R.delayBeforeAsking(launchedAt: nil, sawPlaybackNotification: false, now: now) == 0)
        #expect(R.delayBeforeAsking(launchedAt: now, sawPlaybackNotification: true, now: now) == 0)
        #expect(R.delayBeforeAsking(launchedAt: now, sawPlaybackNotification: false, now: now) == 4)
        #expect(R.delayBeforeAsking(launchedAt: now.addingTimeInterval(-1), sawPlaybackNotification: false, now: now) == 3)
        #expect(R.delayBeforeAsking(launchedAt: now.addingTimeInterval(-10), sawPlaybackNotification: false, now: now) == 0)
        #expect(R.delayBeforeAsking(launchedAt: now.addingTimeInterval(5), sawPlaybackNotification: false, now: now) == 4)
    }

    @Test func resetCommand() {
        #expect(
            MediaPermissionReset.arguments(bundleID: "io.github.snakez3101.supernotch")
                == ["reset", "AppleEvents", "io.github.snakez3101.supernotch"])
        #expect(MediaPermissionReset.executablePath == "/usr/bin/tccutil")
        #expect(
            MediaPermissionReset.terminalCommand(bundleID: "io.github.snakez3101.supernotch")
                == "tccutil reset AppleEvents io.github.snakez3101.supernotch")
        #expect(MediaPermissionReset.terminalCommand(bundleID: nil) == "tccutil reset AppleEvents io.github.snakez3101.supernotch")
        for bad in ["", "a b", "x;rm -rf ~", ".hidden", "-flag", "com.ex$ample", String(repeating: "a", count: 300)] {
            #expect(MediaPermissionReset.sanitizedBundleID(bad) == MediaPermissionReset.fallbackBundleID, "\(bad)")
        }
        #expect(MediaPermissionReset.sanitizedBundleID("com.example.My-App2") == "com.example.My-App2")
    }

    @Test func probeFourCharCodes() {
        typealias P = SpotifyPermissionProbe
        #expect(P.eventClass == 0x636F_7265)  // 'core'
        #expect(P.eventID == 0x6765_7464)  // 'getd'
        #expect(P.keyDirectObject == 0x2D2D_2D2D)  // '----'
        #expect(P.typeObjectSpecifier == 0x6F62_6A20)  // 'obj '
        #expect(P.propertyName == 0x706E_616D)  // 'pnam'
        #expect(P.keyErrorNumber == 0x6572_726E)  // 'errn'
        #expect(P.fourCharCode("abc") == 0)
        #expect(P.fourCharCode("abcde") == 0)
        #expect(P.fourCharCode("ab\u{e9}") == 0)
    }
}

// MARK: - Blocking call runner (timeouts, joining, late answers)

/// Thread-safe recorder for the runner tests.
private final class RunnerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    private var late: [Int32] = []

    func didRun() {
        lock.lock()
        runs += 1
        lock.unlock()
    }

    func didReceiveLate(_ status: Int32) {
        lock.lock()
        late.append(status)
        lock.unlock()
    }

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runs
    }

    var lateStatuses: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return late
    }
}

@Suite("MediaBlockingCallRunner")
struct MediaBlockingCallRunnerTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func fastCallReturnsItsStatus() async {
        let runner = MediaBlockingCallRunner(label: "test.fast")
        let result = await runner.run(timeout: 5, work: { -1743 })
        #expect(result == .status(-1743))
        #expect(!runner.isBusy)
    }

    @Test func hungCallTimesOutAndDeliversTheLateAnswer() async {
        let runner = MediaBlockingCallRunner(label: "test.hung")
        let probe = RunnerProbe()
        let started = Date()
        let result = await runner.run(
            timeout: 0.1,
            work: {
                Thread.sleep(forTimeInterval: 0.6)
                return 0
            },
            late: { probe.didReceiveLate($0) })
        #expect(result == .timedOut)
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(runner.isBusy)
        await waitUntil { probe.lateStatuses == [0] }
        #expect(probe.lateStatuses == [0])
        #expect(!runner.isBusy)
    }

    @Test func callersJoinTheCallInFlight() async {
        let runner = MediaBlockingCallRunner(label: "test.join")
        let probe = RunnerProbe()
        let work: @Sendable () -> Int32 = {
            probe.didRun()
            Thread.sleep(forTimeInterval: 0.3)
            return -1744
        }
        async let first = runner.run(timeout: 5, work: work)
        try? await Task.sleep(for: .milliseconds(50))
        async let second = runner.run(timeout: 5, work: work)
        let results = await [first, second]
        #expect(results == [.status(-1744), .status(-1744)])
        #expect(probe.runCount == 1)

        // Once it finished, the next caller runs the work again.
        let third = await runner.run(timeout: 5, work: work)
        #expect(third == .status(-1744))
        #expect(probe.runCount == 2)
    }

    @Test func aJoinerTimesOutIndependently() async {
        let runner = MediaBlockingCallRunner(label: "test.joiner")
        let probe = RunnerProbe()
        async let first = runner.run(
            timeout: 5,
            work: {
                Thread.sleep(forTimeInterval: 0.4)
                return 0
            })
        try? await Task.sleep(for: .milliseconds(50))
        let joiner = await runner.run(timeout: 0.05, work: { -1 }, late: { probe.didReceiveLate($0) })
        #expect(joiner == .timedOut)
        #expect(await first == .status(0))
        await waitUntil { probe.lateStatuses == [0] }
        #expect(probe.lateStatuses == [0])
    }

    @Test func firstClaimWinsOnce() {
        let claim = MediaFirstClaim()
        #expect(claim.claim())
        #expect(!claim.claim())
    }
}
