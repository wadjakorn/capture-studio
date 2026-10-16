import AppKit
import SwiftUI

/// "Recording saved" toast shown when the user opted out of auto-opening Studio.
/// A non-activating panel that never becomes key, so it cannot steal focus from
/// whatever app the user was in (e.g. when stopping via the global hotkey).
/// One static panel: a new `show` replaces any toast still on screen.
@MainActor
enum RecordingSavedToast {
    private static var panel: NSPanel?
    private static var timer: Timer?
    private static let lifetime: TimeInterval = 6
    private static let inset: CGFloat = 16

    static func show(bundleURL: URL) {
        dismiss()

        let view = RecordingSavedToastView(
            name: bundleURL.deletingPathExtension().lastPathComponent,
            onOpen: {
                StudioLauncher.open(bundleURL: bundleURL)
                dismiss()
            },
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
                dismiss()
            },
            onClose: { dismiss() },
            onHover: { hovering in
                if hovering { timer?.invalidate(); timer = nil } else { startTimer() }
            })
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.identifier = NSUserInterfaceItemIdentifier("chrome.savedToast")
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = host

        if let vis = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(CGPoint(x: vis.maxX - size.width - inset,
                                     y: vis.maxY - size.height - inset))
        }
        p.orderFrontRegardless()
        panel = p
        startTimer()
    }

    static func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { _ in
            Task { @MainActor in dismiss() }
        }
    }
}

private struct RecordingSavedToastView: View {
    let name: String
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Recording saved").font(.headline)
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Button("Open in Studio", action: onOpen)
                    Button("Show in Finder", action: onReveal)
                }
                .controlSize(.small)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onHover(perform: onHover)
    }
}
