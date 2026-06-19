import SwiftUI

/// Live state for the floating area-selection control bar. The `AreaSelector`
/// coordinator owns one of these, mutates the `@Published` fields as the drag
/// changes, and wires the callbacks back to itself.
@MainActor
final class AreaControlModel: ObservableObject {
    @Published var sizeText: String = ""
    /// Selection is at least `minSize` in both dimensions (mirrors
    /// `RegionEditState.isValid`). Reported to the session; not shown in the bar.
    @Published var valid: Bool = false
    @Published var aspect: AspectRatio = .free

    var onPickAspect: (AspectRatio) -> Void = { _ in }
}

/// Floating toolbar shown during area selection: aspect-ratio chips, a live size
/// readout, and Cancel / Use Area. Rendered into a borderless panel via
/// `NSHostingView`; styled dark to read on top of the dimmed overlay.
struct AreaControlBar: View {
    @ObservedObject var model: AreaControlModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(AspectRatio.all, id: \.label) { ratio in
                    chip(ratio)
                }
            }

            Divider().frame(height: 16).overlay(.white.opacity(0.25))

            Text(model.sizeText.isEmpty ? "Drag to select" : model.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .frame(minWidth: 96, alignment: .leading)

            Divider().frame(height: 16).overlay(.white.opacity(0.25))

            Text("Enter to record · Esc to cancel")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .fixedSize()
    }

    private func chip(_ ratio: AspectRatio) -> some View {
        let selected = model.aspect == ratio
        return Button {
            model.onPickAspect(ratio)
        } label: {
            Text(ratio.label)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(selected ? Color.accentColor : Color.white.opacity(0.12),
                            in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help(ratio.hint)
    }
}

private extension AspectRatio {
    /// Platform association shown on hover.
    var hint: String {
        switch label {
        case "16:9": return "Landscape · YouTube"
        case "9:16": return "Vertical · TikTok / Reels"
        case "1:1": return "Square · Instagram post"
        case "4:5": return "Portrait · Instagram feed"
        case "4:3": return "Classic · slides / iPad"
        default: return "Freeform"
        }
    }
}
