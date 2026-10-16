import AppKit
import CoreGraphics

/// Live state of one registered content window, captured on the main actor so
/// the filtering rule below stays pure and unit-testable.
struct ContentWindowInfo: Equatable, Sendable {
    let windowNumber: Int
    let isVisible: Bool
    let isMiniaturized: Bool
    /// Window numbers of sheets attached to this window (close-guard alert,
    /// export panels…). They belong to the content, so they're captured too.
    let sheetNumbers: [Int]
}

/// Which of our own windows the screen capture lets through. The app is
/// excluded wholesale and only these IDs are excepted — an allowlist, so any
/// chrome (popup, HUD, overlays, toast, future panels) stays out by default.
enum CaptureFilterPolicy {
    /// IDs of ordered-in (covered or not), non-minimized content windows plus their
    /// sheets, limited to what ScreenCaptureKit currently lists (`available` =
    /// on-screen `SCWindow.windowID`s of our pid; an `SCWindow` can only be
    /// excepted if SCK knows about it).
    static func exceptedWindowIDs(content: [ContentWindowInfo],
                                  available: Set<CGWindowID>) -> [CGWindowID] {
        candidateIDs(content).filter { available.contains($0) }
    }

    /// True when a window that should be captured isn't in SCK's list yet —
    /// typically one just ordered in, which SCK reports a beat later. The
    /// caller retries once so it doesn't stay missing until the next change.
    static func hasUnlistedVisibleWindow(content: [ContentWindowInfo],
                                         available: Set<CGWindowID>) -> Bool {
        candidateIDs(content).contains { !available.contains($0) }
    }

    /// `windowNumber <= 0` means not ordered in yet (no window-server ID).
    private static func candidateIDs(_ content: [ContentWindowInfo]) -> [CGWindowID] {
        content
            .filter { $0.isVisible && !$0.isMiniaturized && $0.windowNumber > 0 }
            .flatMap { [$0.windowNumber] + $0.sheetNumbers.filter { $0 > 0 } }
            .map { CGWindowID($0) }
    }
}

/// Serializes filter refreshes without ever dropping one. A change that
/// arrives mid-refresh may postdate the snapshot that refresh took, so it
/// marks the run dirty and forces one more pass — skipping it instead could
/// leave a newly opened window out of the video until the next change.
struct RefreshCoalescer {
    private var running = false
    private var dirty = false

    /// true = start a refresh now; false = one is running, rerun queued.
    mutating func request() -> Bool {
        if running {
            dirty = true
            return false
        }
        running = true
        return true
    }

    /// Call when a refresh pass ends. true = a change arrived meanwhile, run
    /// again; false = idle.
    mutating func finish() -> Bool {
        if dirty {
            dirty = false
            return true
        }
        running = false
        return false
    }
}

/// Registry of the app's *content* windows (Studio, Dashboard) — the only own
/// windows allowed into screen.mp4. Recording chrome never registers, so it
/// can't leak in. Windows are held weakly and their IDs read at refresh time
/// (a window has no `windowNumber` until it is first ordered in).
@MainActor
final class CaptureContentWindows {
    static let shared = CaptureContentWindows()

    /// Fired whenever the set of capturable windows may have changed. The
    /// recording session refreshes the stream filter in response.
    var onChange: (() -> Void)?

    private struct Entry {
        weak var window: NSWindow?
        let observers: [NSObjectProtocol]
    }
    private var entries: [ObjectIdentifier: Entry] = [:]

    private init() {}

    /// Occlusion notifications are refresh *triggers* only (they fire on
    /// show/close/miniaturize/Space switch/hide-unhide) — the snapshot doesn't
    /// read occlusion. Sheets don't change the parent's occlusion, so they're
    /// observed apart.
    func register(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let existing = entries[key] {
            if existing.window === window { return }
            // Stale entry whose window died without unregistering and whose
            // address got reused — drop its observers before re-registering.
            existing.observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didEndSheetNotification,
        ]
        let observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                // Deferred one main-loop turn: willBeginSheet posts before the
                // sheet is in `sheets` / ordered in, so an immediate snapshot
                // would miss it. Harmless delay for the other notifications.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.onChange?() }
                }
            }
        }
        entries[key] = Entry(window: window, observers: observers)
        // Deferred like the notifications: callers register before ordering
        // the window in, so it has no window number (-1) yet and an immediate
        // refresh would leave it out of the video.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    func unregister(_ window: NSWindow) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.observers.forEach { NotificationCenter.default.removeObserver($0) }
        onChange?()
    }

    /// `isVisible` is "ordered in and not minimized", NOT occlusion: a Studio
    /// window fully covered by another app must stay excepted, or on Cmd-Tab
    /// back the video shows what was behind it until a refresh lands.
    /// Off-Space/hidden windows are dropped by ScreenRecorder's `isOnScreen`
    /// narrowing of SCK's list instead.
    var snapshot: [ContentWindowInfo] {
        entries.values.compactMap(\.window).map { window in
            ContentWindowInfo(
                windowNumber: window.windowNumber,
                isVisible: window.isVisible && !window.isMiniaturized,
                isMiniaturized: window.isMiniaturized,
                sheetNumbers: window.sheets.map(\.windowNumber)
            )
        }
    }
}
