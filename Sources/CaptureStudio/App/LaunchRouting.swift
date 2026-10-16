import Foundation

/// What a Dock-icon click (reopen) should do. Pure so the rule is testable
/// without AppKit.
enum ReopenAction: Equatable {
    case none
    /// Bring back every minimized Studio/Dashboard window.
    case restoreMinimized
    case showDashboard

    /// `hasVisibleAppWindow` must come from our own launchers (Studio +
    /// Dashboard), not AppKit's `hasVisibleWindows`, which can count the
    /// status-bar window or the menu-bar popup. `hasMiniaturizedWindow` counts
    /// minimized Studio windows and a minimized Dashboard.
    static func decide(hasVisibleAppWindow: Bool, hasMiniaturizedWindow: Bool) -> ReopenAction {
        if hasVisibleAppWindow { return .none }
        if hasMiniaturizedWindow { return .restoreMinimized }
        return .showDashboard
    }

    /// Order to deminiaturize windows in: least recently used first, so the
    /// most recently used one ends up frontmost (and last, to be made key).
    /// Stable for ties, so never-focused windows keep their given order.
    static func restoreOrder<T>(_ windows: [T], lastUsed: (T) -> UInt64) -> [T] {
        windows.enumerated()
            .sorted { (lastUsed($0.element), $0.offset) < (lastUsed($1.element), $1.offset) }
            .map(\.element)
    }
}

enum LaunchRouting {
    /// A plain launch opens the Dashboard; a login-item launch stays
    /// menu-bar-only so logging in doesn't throw a window at the user.
    static func shouldShowDashboardAtLaunch(isLoginItem: Bool) -> Bool {
        !isLoginItem
    }
}
