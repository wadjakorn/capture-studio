import AppKit
import SwiftUI

/// Persistent control bar shown during passive preview (armed, before the
/// countdown). It carries **Record** — the tray popover closes the moment this
/// panel takes key, so once the preview is up the HUD is the user's only way to
/// start the recording. Alongside it:
/// - passive (step 1): what you can do, plus Select Area (Area mode only) and Cancel.
/// - drag mode (step 2): "Done Selecting" toggles back to passive; the
///   AreaSelector's own control bar (aspect + size) shows below it.
///
/// Select Area is offered only in Area mode. Full Display captures the whole
/// screen, so showing it there made an optional detour look like a required step
/// — and left Record nowhere to be found.
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

    /// `onToggleDragMode(true/false)` on the drag toggle; `onRecord` on Record;
    /// `onCancel` on Esc / the Cancel button (passive only). `offersAreaSelection`
    /// shows the Select Area toggle (Area mode); `canRecord` is the initial Record
    /// gate, kept live afterwards via `setCanRecord`.
    init(onDisplay displayID: CGDirectDisplayID?,
         offersAreaSelection: Bool,
         canRecord: Bool,
         onToggleDragMode: @escaping (Bool) -> Void,
         onRecord: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        } ?? NSScreen.main ?? NSScreen.screens.first!

        model = PreviewHUDModel()
        model.offersAreaSelection = offersAreaSelection
        model.canRecord = canRecord
        model.onToggle = onToggleDragMode
        model.onRecord = onRecord
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

    /// Mirror the session's Record gate onto the button, so a blocked start is
    /// visibly blocked rather than a click that silently does nothing.
    func setCanRecord(_ on: Bool) {
        model.canRecord = on
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
    /// Area mode: the Select Area toggle is shown. Full Display: it is not.
    @Published var offersAreaSelection = false
    /// Mirrors `RecordingSession.canBeginArmed`.
    @Published var canRecord = true
    /// Fired only by the user tapping the toggle; external `setDragMode` does not.
    var onToggle: (Bool) -> Void = { _ in }
    var onRecord: () -> Void = {}
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
                    Text(passiveHint)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .fixedSize()
            } else {
                Text("Drag to select · Return to record · Esc to go back")
                    .font(.callout.weight(.medium))
                    .fixedSize()
            }

            if model.offersAreaSelection { toggleButton }

            recordButton

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

    private var passiveHint: String {
        model.offersAreaSelection
            ? "Move or resize the camera · Select Area to change what's captured · Esc to cancel"
            : "Move or resize the camera · Record when you're ready · Esc to cancel"
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

    /// The primary action, live in every stage. Dimmed and inert while the
    /// session blocks recording (Area mode with no area picked yet), so it never
    /// swallows a click without explanation.
    private var recordButton: some View {
        Button { model.onRecord() } label: {
            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                Text("Record").fixedSize()
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Color.red.opacity(model.canRecord ? 0.95 : 0.35)))
            .opacity(model.canRecord ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!model.canRecord)
        .help(model.canRecord ? "Start recording" : "Select an area to record")
    }
}
