import AppKit
import SwiftUI

/// One self-dismissing toast slot: a borderless, non-activating panel that never
/// becomes key, so it cannot steal focus from whatever app the user is in (e.g.
/// when a recording starts or stops via the global hotkey). A new `show`
/// replaces any toast still on screen. Chrome: never registered with
/// `CaptureContentWindows`, so it stays out of `screen.mp4`.
@MainActor
final class ToastPanel {
    enum Placement { case topTrailing, topCenter }

    private let identifier: String
    private let placement: Placement
    private let lifetime: TimeInterval
    private static let inset: CGFloat = 16

    private var panel: NSPanel?
    private var timer: Timer?

    init(identifier: String, placement: Placement, lifetime: TimeInterval) {
        self.identifier = identifier
        self.placement = placement
        self.lifetime = lifetime
    }

    func show<Content: View>(_ content: Content) {
        dismiss()

        let host = NSHostingView(rootView: content)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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
        p.contentView = host

        if let vis = NSScreen.main?.visibleFrame {
            let x: CGFloat
            switch placement {
            case .topTrailing: x = vis.maxX - size.width - Self.inset
            case .topCenter: x = vis.midX - size.width / 2
            }
            p.setFrameOrigin(CGPoint(x: x, y: vis.maxY - size.height - Self.inset))
        }
        p.orderFrontRegardless()
        panel = p
        startTimer()
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Hovering pauses auto-dismiss; leaving restarts the full lifetime.
    func setHovering(_ hovering: Bool) {
        if hovering { timer?.invalidate(); timer = nil } else { startTimer() }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }
}
