import Testing
@testable import CaptureStudio

@Suite struct LaunchRoutingTests {
    @Test func reopenWithVisibleWindowDoesNothing() {
        #expect(ReopenAction.decide(hasVisibleAppWindow: true, hasMiniaturizedWindow: false) == .none)
    }

    @Test func reopenWithVisibleWindowIgnoresMinimizedStudio() {
        #expect(ReopenAction.decide(hasVisibleAppWindow: true, hasMiniaturizedWindow: true) == .none)
    }

    @Test func reopenRestoresMinimizedStudio() {
        #expect(ReopenAction.decide(hasVisibleAppWindow: false, hasMiniaturizedWindow: true) == .restoreMinimized)
    }

    @Test func restoreOrderPutsMostRecentlyUsedLast() {
        let used = ["a": UInt64(3), "b": 0, "c": 7, "d": 0]
        let order = ReopenAction.restoreOrder(["a", "b", "c", "d"]) { used[$0] ?? 0 }
        // Never-used windows keep their given order; most recent ends last.
        #expect(order == ["b", "d", "a", "c"])
        #expect(ReopenAction.restoreOrder([String]()) { _ in 0 }.isEmpty)
    }

    @Test func reopenWithNothingShowsDashboard() {
        #expect(ReopenAction.decide(hasVisibleAppWindow: false, hasMiniaturizedWindow: false) == .showDashboard)
    }

    @Test func loginItemLaunchSkipsDashboard() {
        #expect(!LaunchRouting.shouldShowDashboardAtLaunch(isLoginItem: true))
    }

    @Test func normalLaunchShowsDashboard() {
        #expect(LaunchRouting.shouldShowDashboardAtLaunch(isLoginItem: false))
    }
}
