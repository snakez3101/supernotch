// Owner: notch-shell. Seed tests by the foundation, extended by notch-shell.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("NotchGeometry")
struct NotchGeometryTests {
    // 14" MacBook Pro default scaled resolution: 1512 × 982, notch ≈ 185 × 32.
    let mbp14 = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32, auxiliaryTopLeftWidth: 663.5,
        auxiliaryTopRightWidth: 663.5)
    // 16" MacBook Pro default scaled resolution: 1728 × 1117.
    let mbp16 = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117), safeAreaTop: 32, auxiliaryTopLeftWidth: 771.5,
        auxiliaryTopRightWidth: 771.5)

    @Test func notchRect() throws {
        let geometry = try #require(mbp14)
        #expect(geometry.notchRect == CGRect(x: 663.5, y: 950, width: 185, height: 32))
        #expect(geometry.panelFrame.maxY == 982)
        #expect(geometry.panelFrame.midX == 756)
    }

    @Test func notchRect16Inch() throws {
        let geometry = try #require(mbp16)
        #expect(geometry.notchSize == CGSize(width: 185, height: 32))
        #expect(geometry.notchRect.minY == 1085)
        #expect(geometry.panelFrame == CGRect(x: 864 - 290, y: 1117 - 340, width: 580, height: 340))
    }

    @Test func noNotch() {
        #expect(
            NotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
                auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil) == nil)
    }

    @Test func missingAuxiliaryAreasFallBackToCentredDefault() throws {
        let geometry = try #require(
            NotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: 663.5))
        #expect(geometry.notchSize == CGSize(width: NotchMetrics.fallbackNotchSize.width, height: 32))
        #expect(geometry.notchRect.midX == 756)
    }

    @Test func absurdInsetsAreRejected() {
        // Auxiliary areas that leave (almost) nothing, or a safe area taller than a quarter of the screen.
        #expect(
            NotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                auxiliaryTopLeftWidth: 750, auxiliaryTopRightWidth: 750) == nil)
        #expect(
            NotchGeometry(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 400,
                auxiliaryTopLeftWidth: 663.5, auxiliaryTopRightWidth: 663.5) == nil)
    }

    @Test func secondaryDisplayOrigin() throws {
        // Built-in display left of an external primary display.
        let geometry = try #require(
            NotchGeometry(
                screenFrame: CGRect(x: -1512, y: 98, width: 1512, height: 982), safeAreaTop: 32,
                auxiliaryTopLeftWidth: 663.5, auxiliaryTopRightWidth: 663.5))
        #expect(geometry.notchRect == CGRect(x: -848.5, y: 1048, width: 185, height: 32))
        #expect(geometry.panelFrame.maxY == 1080)
        #expect(geometry.panelFrame.midX == geometry.notchRect.midX)
        #expect(geometry.isOnScreen(frame: CGRect(x: -1512, y: 98, width: 1512, height: 982)))
        #expect(!geometry.isOnScreen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
    }

    @Test func sizesStayCompactAndFitPanel() throws {
        let geometry = try #require(mbp14)
        let expanded = geometry.size(for: .expanded(.home))
        #expect(expanded == CGSize(width: 540, height: 32 + 156))
        #expect(expanded.width <= NotchMetrics.panelSize.width - 24)
        #expect(expanded.height <= NotchMetrics.panelSize.height - 24)
        let request = PopupRequest.claudePermission(requestID: "r", hostAppBundleID: nil, now: Date())
        #expect(geometry.size(for: .peek(request)) == CGSize(width: 480, height: 32 + 128))
        let done = PopupRequest.claudeDone(sessionID: "s", hostAppBundleID: nil, autoDismissAfter: 4, now: Date())
        #expect(geometry.size(for: .peek(done)) == CGSize(width: 420, height: 32 + 64))
        #expect(geometry.size(for: .closed, closedWidthExtra: 72).width == geometry.notchSize.width + 72)
        #expect(geometry.size(for: .closed) == geometry.notchSize)
    }

    @Test func everyStateFitsThePanelWithShoulders() throws {
        let geometry = try #require(mbp16)
        let permission = PopupRequest.claudePermission(requestID: "r", hostAppBundleID: nil, now: Date())
        let states: [(NotchPresentation, CGFloat)] = [
            (.closed, 6), (.peek(permission), 10), (.expanded(.shelf), 12),
        ]
        for (presentation, topRadius) in states {
            let size = geometry.size(for: presentation, closedWidthExtra: 72)
            #expect(size.width + 2 * topRadius <= NotchMetrics.panelSize.width)
            #expect(size.height <= NotchMetrics.panelSize.height)
        }
    }

    @Test func shapeRectIsTopCentred() throws {
        let geometry = try #require(mbp14)
        let rect = geometry.shapeRectInScreen(for: CGSize(width: 540, height: 188))
        #expect(rect == CGRect(x: 756 - 270, y: 982 - 188, width: 540, height: 188))
        #expect(geometry.rectInPanel(rect) == CGRect(x: 20, y: 0, width: 540, height: 188))
    }

    @Test func closedShapeFollowsItsWings() throws {
        let geometry = try #require(mbp14)
        // Usage warning only: a lone 14 pt right wing; the left edge stays on the physical notch.
        let warning = geometry.shapeRectInScreen(for: .closed, wings: NotchClosedWings(trailing: 14))
        #expect(warning.minX == geometry.notchRect.minX)
        #expect(warning.maxX == geometry.notchRect.maxX + 14)
        #expect(warning.maxY == 982)
        let island = geometry.shapeRectInScreen(for: .closed, wings: NotchClosedWings(leading: 36, trailing: 36))
        #expect(island.minX == geometry.notchRect.minX - 36)
        #expect(island.maxX == geometry.notchRect.maxX + 36)
        // Open shapes ignore the wings and stay centred.
        let expanded = geometry.shapeRectInScreen(for: .expanded(.home), wings: NotchClosedWings(trailing: 14))
        #expect(expanded.width == 540)
        #expect(expanded.midX == geometry.notchRect.midX)
    }

    @Test func triggerCoversVisibleWingsOnly() throws {
        let geometry = try #require(mbp14)
        #expect(geometry.triggerRect(wings: .none, slack: 6) == geometry.hoverRect(slack: 6))
        let island = geometry.triggerRect(wings: NotchClosedWings(leading: 36, trailing: 36), slack: 6)
        #expect(island.minX == geometry.notchRect.minX - 42)
        #expect(island.maxX == geometry.notchRect.maxX + 42)
        #expect(island.minY == geometry.notchRect.minY)
        #expect(!island.contains(CGPoint(x: geometry.notchRect.minX - 50, y: 970)))
        let warning = geometry.triggerRect(wings: NotchClosedWings(trailing: 14), slack: 6)
        #expect(warning.minX == geometry.notchRect.minX - 6)
        #expect(warning.maxX == geometry.notchRect.maxX + 20)
    }

    @Test func hoverRectOnlyCoversThePhysicalNotchPlusSlack() throws {
        let geometry = try #require(mbp14)
        let hover = geometry.hoverRect(slack: 6)
        #expect(hover.minX == 657.5)
        #expect(hover.maxX == 854.5)
        #expect(hover.minY == 950)
        #expect(hover.contains(CGPoint(x: 756, y: 982)))  // very top pixel row
        #expect(!hover.contains(CGPoint(x: 756, y: 940)))  // below the notch
        #expect(!hover.contains(CGPoint(x: 600, y: 970)))  // menu bar beside the notch
    }

    @Test func leaveRectAddsMargin() throws {
        let geometry = try #require(mbp14)
        let shape = geometry.shapeRectInScreen(for: CGSize(width: 540, height: 188))
        let leave = geometry.leaveRect(for: shape, margin: 8)
        #expect(leave.minX == shape.minX - 8)
        #expect(leave.maxX == shape.maxX + 8)
        #expect(leave.minY == shape.minY - 8)
        #expect(leave.maxY >= 982)
    }

    @Test func pointInPanel() throws {
        let geometry = try #require(mbp14)
        let point = geometry.pointInPanel(CGPoint(x: 756, y: 982))
        #expect(point == CGPoint(x: 290, y: 0))
    }
}

@Suite("NotchClosedWings")
struct NotchClosedWingsTests {
    @Test func resolveMatchesTheFoundationRule() {
        for mode in ClosedNotchMode.allCases {
            for content in [false, true] {
                for warning in [false, true] {
                    let rule = NotchMetrics.closedWings(mode: mode, hasIslandContent: content, showsUsageWarning: warning)
                    let wings = NotchClosedWings.resolve(mode: mode, hasIslandContent: content, showsUsageWarning: warning)
                    #expect(wings.leading == rule.leading)
                    #expect(wings.trailing == rule.trailing)
                    #expect(
                        wings.total
                            == NotchMetrics.closedWidthExtra(
                                mode: mode, hasIslandContent: content, showsUsageWarning: warning))
                }
            }
        }
    }

    @Test func warningWingShiftsTheShapeRight() {
        let wings = NotchClosedWings.resolve(mode: .invisible, hasIslandContent: false, showsUsageWarning: true)
        #expect(wings == NotchClosedWings(trailing: NotchMetrics.warningWingWidth))
        #expect(wings.centerOffset == 7)
    }

    @Test func islandIsSymmetric() {
        let wings = NotchClosedWings.resolve(mode: .island, hasIslandContent: true, showsUsageWarning: true)
        #expect(wings.centerOffset == 0)
        #expect(wings.total == 2 * NotchMetrics.islandWingWidth)
    }

    @Test func negativeWidthsClamp() {
        #expect(NotchClosedWings(leading: -3, trailing: -1).isEmpty)
    }
}

@Suite("NotchFullscreenHeuristic")
struct NotchFullscreenHeuristicTests {
    // Built-in 14" display as primary: Quartz frame equals AppKit frame for the primary display.
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let appPID: Int32 = 42
    let menuBar = NotchWindowSample(ownerPID: 1, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1512, height: 32))

    @Test func quartzConversion() {
        let appKit = CGRect(x: -1512, y: 98, width: 1512, height: 982)
        #expect(
            NotchFullscreenHeuristic.quartzRect(fromAppKit: appKit, primaryScreenHeight: 1080)
                == CGRect(x: -1512, y: 0, width: 1512, height: 982))
    }

    @Test func fullFrameWindowOfFrontmostAppIsFullscreen() {
        let windows = [NotchWindowSample(ownerPID: appPID, layer: 0, bounds: screen)]
        #expect(
            NotchFullscreenHeuristic.isFullscreen(
                windows: windows, frontmostPID: appPID, screenFrame: screen, notchHeight: 32))
    }

    @Test func belowNotchWindowCountsOnlyWithoutMenuBar() {
        let belowNotch = NotchWindowSample(
            ownerPID: appPID, layer: 0, bounds: CGRect(x: 0, y: 32, width: 1512, height: 950))
        #expect(
            NotchFullscreenHeuristic.isFullscreen(
                windows: [belowNotch], frontmostPID: appPID, screenFrame: screen, notchHeight: 32))
        // A zoomed window with a hidden Dock has the same bounds, but the menu bar is visible.
        #expect(
            !NotchFullscreenHeuristic.isFullscreen(
                windows: [menuBar, belowNotch], frontmostPID: appPID, screenFrame: screen, notchHeight: 32))
    }

    @Test func otherAppsAndLayersDoNotCount() {
        let otherApp = NotchWindowSample(ownerPID: 7, layer: 0, bounds: screen)
        let overlay = NotchWindowSample(ownerPID: appPID, layer: 25, bounds: screen)
        #expect(
            !NotchFullscreenHeuristic.isFullscreen(
                windows: [otherApp, overlay], frontmostPID: appPID, screenFrame: screen, notchHeight: 32))
    }

    @Test func ordinaryWindowIsNotFullscreen() {
        let window = NotchWindowSample(ownerPID: appPID, layer: 0, bounds: CGRect(x: 100, y: 60, width: 900, height: 700))
        #expect(
            !NotchFullscreenHeuristic.isFullscreen(
                windows: [menuBar, window], frontmostPID: appPID, screenFrame: screen, notchHeight: 32))
    }

    @Test func fullscreenOnAnotherDisplayDoesNotCount() {
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let windows = [NotchWindowSample(ownerPID: appPID, layer: 0, bounds: external)]
        #expect(
            !NotchFullscreenHeuristic.isFullscreen(
                windows: windows, frontmostPID: appPID, screenFrame: screen, notchHeight: 32))
    }
}
