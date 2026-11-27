import AppKit
import SwiftUI

/// "Recording saved" toast shown when the user opted out of auto-opening Studio.
/// A non-activating `ToastPanel` that never becomes key, so it cannot steal focus
/// from whatever app the user was in (e.g. when stopping via the global hotkey).
/// One static panel: a new `show` replaces any toast still on screen.
@MainActor
enum RecordingSavedToast {
    private static let toast = ToastPanel(identifier: "chrome.savedToast",
                                          placement: .topTrailing, lifetime: 6)

    static func show(bundleURL: URL) {
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
            onHover: { toast.setHovering($0) })
        toast.show(view)
    }

    static func dismiss() {
        toast.dismiss()
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
