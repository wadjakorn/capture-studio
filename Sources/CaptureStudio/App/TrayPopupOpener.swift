import AppKit

/// Opens the MenuBarExtra popup programmatically. SwiftUI has no API for this,
/// so we click the status item's button. This is the ONLY file that knows the
/// private AppKit hierarchy (`NSStatusBarWindow` → `NSStatusBarButton`); keep
/// it that way.
///
/// Unverified: Mac spike S0.3 must confirm `performClick` on that button opens
/// the `.window`-style popup (idle and while recording, with and without other
/// app windows). If it doesn't, the fallback is replacing MenuBarExtra with our
/// own `NSStatusItem` + `NSPopover`, which we can open directly.
@MainActor
enum TrayPopupOpener {
    /// Whether `open()` can succeed right now: the popup is already up or the
    /// status bar button can be located. Lets callers keep their own window
    /// on screen instead of leaving the user with nothing.
    static func canOpen() -> Bool {
        isPopupOpen() || statusItemButton() != nil
    }

    /// Returns false (and logs) when the status button can't be found; callers
    /// should check `canOpen()` first when failing would strand the user.
    @discardableResult
    static func open() -> Bool {
        // performClick toggles: if the popup is already up, a click would close
        // it. Best-effort detection by SwiftUI's private window class name
        // (unverified, S0.3); if the name differs this just never matches and
        // we click as before.
        if isPopupOpen() {
            Log.app.info("TrayPopupOpener: popup already open; not clicking")
            return true
        }
        guard let button = statusItemButton() else {
            Log.app.error("TrayPopupOpener: NSStatusBarButton not found; popup not opened")
            return false
        }
        button.performClick(nil)
        return true
    }

    private static func isPopupOpen() -> Bool {
        NSApp.windows.contains {
            $0.isVisible && String(describing: type(of: $0)).contains("MenuBarExtraWindow")
        }
    }

    private static func statusItemButton() -> NSButton? {
        let statusWindows = NSApp.windows.filter {
            String(describing: type(of: $0)).contains("NSStatusBarWindow")
        }
        for window in statusWindows {
            if let button = findStatusButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func findStatusButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, isStatusBarButton(button) { return button }
        for subview in view.subviews {
            if let found = findStatusButton(in: subview) { return found }
        }
        return nil
    }

    private static func isStatusBarButton(_ button: NSButton) -> Bool {
        if let cls = NSClassFromString("NSStatusBarButton"), button.isKind(of: cls) { return true }
        return String(describing: type(of: button)).contains("NSStatusBarButton")
    }
}
