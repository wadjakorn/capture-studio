import Foundation

/// What a Dock-icon click (reopen) should do. Pure so the rule is testable
/// without AppKit.
enum ReopenAction: Equatable {
    case none
    case restoreStudio
    case showDashboard

    /// `hasVisibleAppWindow` must come from our own launchers (Studio +
    /// Dashboard), not AppKit's `hasVisibleWindows`, which can count the
    /// status-bar window or the menu-bar popup.
    static func decide(hasVisibleAppWindow: Bool, hasMiniaturizedStudio: Bool) -> ReopenAction {
        if hasVisibleAppWindow { return .none }
        if hasMiniaturizedStudio { return .restoreStudio }
        return .showDashboard
    }
}

enum LaunchRouting {
    /// A plain launch opens the Dashboard; a login-item launch stays
    /// menu-bar-only so logging in doesn't throw a window at the user.
    static func shouldShowDashboardAtLaunch(isLoginItem: Bool) -> Bool {
        !isLoginItem
    }
}
