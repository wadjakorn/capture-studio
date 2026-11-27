import AppKit
import SwiftUI

/// One self-dismissing toast slot: a borderless, non-activating panel that never
/// becomes key, so it cannot steal focus from whatever app the user is in (e.g.
/// when a recording starts or stops via the global hotkey). A new `show`
/// replaces any toast still on screen. Chrome: never registered with
/// `CaptureContentWindows`, so it stays out of `screen.mp4`.
///
/// The panel is created once, in `init`, and reused: `show` swaps its content,
/// `dismiss` only orders it out. A window that exists before a take starts is
/// one the screen recorder's fail-closed fallback filter (which drops only the
/// windows listed when the filter is built) already knows to exclude.
@MainActor
final class ToastPanel {
    enum Placement { case topTrailing, topCenter }

    private let placement: Placement
    private let lifetime: TimeInterval
    private let onDismiss: (@MainActor () -> Void)?
    private static let inset: CGFloat = 16

    private let panel: NSPanel
    private var timer: Timer?
    /// Bumped whenever the timer stops, so a fire already queued on the main
    /// actor can't dismiss a toast shown (or hovered) after it.
    private var timerToken = 0
    private var isShowing = false

    /// `onDismiss` runs on every `dismiss` — explicit or the lifetime timeout.
    init(identifier: String, placement: Placement, lifetime: TimeInterval,
         onDismiss: (@MainActor () -> Void)? = nil) {
        self.placement = placement
        self.lifetime = lifetime
        self.onDismiss = onDismiss

        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.identifier = NSUserInterfaceItemIdentifier(identifier)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        panel = p
    }

    func show<Content: View>(_ content: Content) {
        stopTimer()

        let host = NSHostingView(rootView: content)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        panel.contentView = host
        panel.setContentSize(size)
        if let vis = NSScreen.main?.visibleFrame {
            let x: CGFloat
            switch placement {
            case .topTrailing: x = vis.maxX - size.width - Self.inset
            case .topCenter: x = vis.midX - size.width / 2
            }
            panel.setFrameOrigin(CGPoint(x: x, y: vis.maxY - size.height - Self.inset))
        }
        panel.orderFrontRegardless()
        // The shadow follows the drawn content; a reused panel's would still
        // trace the previous toast's shape.
        panel.invalidateShadow()
        isShowing = true
        startTimer()
    }

    func dismiss() {
        stopTimer()
        isShowing = false
        panel.orderOut(nil)
        onDismiss?()
    }

    /// Hovering pauses auto-dismiss; leaving restarts the full lifetime.
    func setHovering(_ hovering: Bool) {
        if hovering { stopTimer() } else if isShowing { startTimer() }
    }

    private func startTimer() {
        stopTimer()
        let token = timerToken
        timer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.timerToken == token else { return }
                self.dismiss()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        timerToken &+= 1
    }
}
