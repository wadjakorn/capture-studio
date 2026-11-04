import AppKit
import SwiftUI

/// Floating "Confirm 483 921 on <phone>" prompt shown while a Wi-Fi phone is
/// being paired during arm. Non-activating (never steals focus), bottom-center
/// of `NSScreen.main`, app-owned → excluded from screen.mp4. Cancel / Esc
/// abandons the arm, which closes the phone connection.
@MainActor
final class PairingPanel {
    private let panel: PairingNSPanel
    private let model: PairingPanelModel

    init(prompt: PairingPrompt, onCancel: @escaping () -> Void) {
        model = PairingPanelModel(prompt: prompt, onCancel: onCancel)
        let host = NSHostingView(rootView: PairingPanelView(model: model))
        host.layoutSubtreeIfNeeded()
        panel = PairingNSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.onCancel = onCancel
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = host
        reposition()
    }

    func show() {
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func update(_ prompt: PairingPrompt) {
        model.prompt = prompt
        reposition()
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Bottom-center of the main screen, above the preview HUD's row.
    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2,
                                     y: screen.frame.minY + 200))
    }
}

/// Non-activating panel that can be key so Esc cancels.
private final class PairingNSPanel: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }
}

@MainActor
private final class PairingPanelModel: ObservableObject {
    @Published var prompt: PairingPrompt
    let onCancel: () -> Void
    init(prompt: PairingPrompt, onCancel: @escaping () -> Void) {
        self.prompt = prompt
        self.onCancel = onCancel
    }
}

private struct PairingPanelView: View {
    @ObservedObject var model: PairingPanelModel

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Confirm")
                        .font(.title3)
                    Text(PairingCode.formatted(model.prompt.code))
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                    Text("on \(model.prompt.phoneName)")
                        .font(.title3)
                }
                Text("Check that the same code is shown on your phone, then tap Allow on the phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") { model.onCancel() }
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
