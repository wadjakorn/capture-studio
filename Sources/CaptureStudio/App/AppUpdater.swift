import AppKit
import Combine
import Foundation
import Sparkle

/// Sparkle 2 auto-update. Feed (`SUFeedURL`) and EdDSA public key
/// (`SUPublicEDKey`) live in Info.plist; the appcast is published as a
/// GitHub Release asset by `scripts/make-appcast.sh`.
///
/// Inert when not running from a `.app` bundle (`swift run`, tests) or when
/// the plist lacks a feed/key, so dev runs never hit the network or show an
/// "updater misconfigured" alert.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// Drives the "Check for Updates…" button (false while a check runs).
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?

    var isEnabled: Bool { controller != nil }

    private override init() {
        super.init()
        guard Self.isConfigured(Bundle.main) else {
            Log.app.info("Updater: disabled (not a configured .app bundle)")
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Call once at launch: touching `shared` creates the controller, which
    /// starts Sparkle's scheduled background checks.
    func start() {}

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    nonisolated static func isConfigured(_ bundle: Bundle) -> Bool {
        guard bundle.bundleURL.pathExtension == "app",
              let info = bundle.infoDictionary,
              let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty
        else { return false }
        return true
    }
}

// The app is LSUIElement (menu-bar only most of the time), so Sparkle needs
// "gentle reminders" support: a scheduled update found in the background must
// not pop a window behind other apps without bringing it forward.
extension AppUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let Sparkle show its window; we just make sure it comes to front.
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        DispatchQueue.main.async {
            NSApplication.shared.activate()
        }
    }
}
