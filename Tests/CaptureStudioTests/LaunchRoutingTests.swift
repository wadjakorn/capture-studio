import Testing
@testable import CaptureStudio

@Suite struct LaunchRoutingTests {
    @Test func reopenWithVisibleWindowDoesNothing() {
        #expect(ReopenAction.decide(hasVisibleAppWindow: true, hasMiniaturizedStudio: false) == .none)
    }

    @Test func reopenWithVisibleWindowIgnoresMinimizedStudio() {
        #expect(ReopenAction.decide(hasVisibleAppWindow: true, hasMiniaturizedStudio: true) == .none)
    }

    @Test func reopenRestoresMinimizedStudio() {
        #expect(ReopenAction.decide(hasVisibleAppWindow: false, hasMiniaturizedStudio: true) == .restoreStudio)
    }

    @Test func reopenWithNothingShowsDashboard() {
        #expect(ReopenAction.decide(hasVisibleAppWindow: false, hasMiniaturizedStudio: false) == .showDashboard)
    }

    @Test func loginItemLaunchSkipsDashboard() {
        #expect(!LaunchRouting.shouldShowDashboardAtLaunch(isLoginItem: true))
    }

    @Test func normalLaunchShowsDashboard() {
        #expect(LaunchRouting.shouldShowDashboardAtLaunch(isLoginItem: false))
    }
}
