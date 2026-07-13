import AppKit
import SwiftUI

/// Persistent suggestion bar shown during passive preview (armed, before the
/// countdown). Advises the user what they can do and carries the drag-mode
/// toggle plus a Cancel affordance:
/// - passive (step 1): "interact freely / Select Area / Esc to cancel".
/// - drag mode (step 2): compact "Done Selecting" toggle; the AreaSelector's own
///   control bar (aspect + size) shows below it.
///
/// App-owned → excluded from screen.mp4. A non-activating panel that CAN become
/// key, so ESC cancels the preview without the user first re-focusing the tray.
/// Sits above the selection overlay's panels (`.screenSaver`) so its controls
/// stay clickable while drag mode is on.
@MainActor
final class PreviewHUD {
    private let panel: KeyableHUDPanel
    private let model: PreviewHUDModel
    private let screen: NSScreen

    /// `onToggleDragMode(true/false)` on the drag toggle; `onCancel` on Esc /
    /// the Cancel button (passive only).
    init(onDisplay displayID: CGDirectDisplayID?,
         onToggleDragMode: @escaping (Bool) -> Void,
         onCancel: @escaping () -> Void) {
        screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        } ?? NSScreen.main ?? NSScreen.screens.first!

        model = PreviewHUDModel()
        model.onToggle = onToggleDragMode
        model.onCancel = onCancel

        let host = NSHostingView(rootView: PreviewHUDView(model: model))
        host.layoutSubtreeIfNeeded()

        panel = KeyableHUDPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.onCancel = onCancel
        // Above the selection overlay (`.screenSaver`) and its control bar
        // (`.screenSaver + 1`) so the bar stays on top and clickable in both modes.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = host
        reposition(size: host.fittingSize)
    }

    func show() {
        panel.orderFrontRegardless()
        // Become key (without activating the app) so ESC reaches us right away,
        // instead of only after the user re-focuses the menu-bar popover.
        panel.makeKey()
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Reflect a drag-mode change from outside the HUD (Esc in the overlay,
    /// teardown) so the toggle stays in sync without re-firing onToggle. Also
    /// resizes/repositions since the two layouts differ in width.
    func setDragMode(_ on: Bool) {
        model.dragMode = on
        if let host = panel.contentView {
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            panel.setContentSize(size)
            reposition(size: size)
        }
    }

    /// Bottom-center of the target screen, above the AreaSelector control bar
    /// (minY + 72) so the two never overlap in drag mode.
    private func reposition(size: NSSize) {
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.minY + 130
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }
}

/// Borderless non-activating panel that can still be key, so ESC (routed to
/// `cancelOperation`) fires our cancel even while the app is not frontmost.
private final class KeyableHUDPanel: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class PreviewHUDModel: ObservableObject {
    @Published var dragMode = false
    /// Fired only by the user tapping the toggle; external `setDragMode` does not.
    var onToggle: (Bool) -> Void = { _ in }
    var onCancel: () -> Void = {}
}

private struct PreviewHUDView: View {
    @ObservedObject var model: PreviewHUDModel

    var body: some View {
        HStack(spacing: 12) {
            if !model.dragMode {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Previewing — interact with anything on screen")
                        .font(.callout.weight(.medium))
                    Text("Move or resize the camera · Select Area to change what's captured · Esc to cancel")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .fixedSize()
            } else {
                Text("Drag to select · Return to record · Esc to go back")
                    .font(.callout.weight(.medium))
                    .fixedSize()
            }

            toggleButton

            if !model.dragMode {
                Button { model.onCancel() } label: {
                    Text("Cancel").font(.callout.weight(.medium)).fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.black.opacity(0.8)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .padding(4)
        .fixedSize()
    }

    private var toggleButton: some View {
        Button {
            let next = !model.dragMode
            model.dragMode = next
            model.onToggle(next)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.dragMode ? "checkmark" : "crop")
                Text(model.dragMode ? "Done Selecting" : "Select Area").fixedSize()
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(model.dragMode
                ? Color.accentColor.opacity(0.95)
                : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
