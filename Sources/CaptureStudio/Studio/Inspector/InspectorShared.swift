import SwiftUI
import AppKit

/// Reports the natural (padded) height of a style popover's content so the
/// popover frame can fit it up to a cap instead of using a fixed height.
struct StylePopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Curated font families (Core Text resolves by family name; unknown names
/// fall back to the system font).
let inspectorFontFamilies = [
    "Helvetica", "Helvetica Neue", "Arial", "Avenir Next",
    "Georgia", "Futura", "Menlo", "Times New Roman",
]

/// Common border colors offered as one-tap swatches.
let inspectorBorderPresets = [
    "#FFFFFF", "#000000", "#FF3B30", "#FF9500",
    "#34C759", "#007AFF", "#AF52DE", "#8E8E93",
]

@MainActor func styleSlider(_ title: String, value: Binding<Double>,
                 range: ClosedRange<Double>, model: StudioModel) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Slider(value: value, in: range) { editing in
            if editing { model.beginStyleEdit() } else { model.endStyleEdit() }
        }
    }
}

@MainActor func styleSliderText(_ title: String, value: Binding<Double>,
                     range: ClosedRange<Double>, model: StudioModel) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Slider(value: value, in: range) { editing in
            if !editing { model.commitTextEdit() }
        }
    }
}

@MainActor func styleSliderSubtitle(_ title: String, value: Binding<Double>,
                         range: ClosedRange<Double>, model: StudioModel) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Slider(value: value, in: range) { editing in
            if !editing { model.commitSubtitleEdit() }
        }
    }
}

@MainActor func volumeSlider(systemImage: String, help: String,
                  value: Binding<Double>,
                  range: ClosedRange<Double> = 0...1,
                  showPercent: Bool = false, model: StudioModel) -> some View {
    HStack(spacing: 4) {
        Image(systemName: systemImage)
            .foregroundStyle(.secondary)
        Slider(value: value, in: range) { editing in
            if !editing { model.commitVolumeEdit() }
        }
        .frame(width: 80)
        .controlSize(.small)
        if showPercent {
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
    .help(help)
}

/// Preset swatches + custom picker for a text color field.
@MainActor func textColorRow(_ title: String, hex: String,
                  set: @escaping (String) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        FlowLayout(hSpacing: 6, vSpacing: 6) {
            ForEach(inspectorBorderPresets, id: \.self) { h in
                let selected = h.caseInsensitiveCompare(hex) == .orderedSame
                Circle()
                    .fill(Color(hexString: h))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                    .overlay(Circle().strokeBorder(Color.accentColor,
                                                   lineWidth: selected ? 2.5 : 0).padding(-2))
                    .onTapGesture { set(h) }
            }
            ColorPicker("", selection: Binding(
                get: { Color(hexString: hex) },
                set: { set($0.hexString()) }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }
}

/// Preset swatches plus a compact custom picker. Tapping a swatch sets the
/// border color inline; only the custom picker opens the system panel.
@MainActor func borderColorControls(model: StudioModel) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text("Border color").font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 6) {
            ForEach(inspectorBorderPresets, id: \.self) { hex in
                let selected = hex.caseInsensitiveCompare(model.cameraBorderHex) == .orderedSame
                Circle()
                    .fill(Color(hexString: hex))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                    .overlay(
                        Circle().strokeBorder(Color.accentColor,
                                              lineWidth: selected ? 2.5 : 0)
                            .padding(-2)
                    )
                    .onTapGesture { model.setCameraBorderHex(hex) }
            }
        }
        ColorPicker("Custom", selection: Binding(
            get: { Color(hexString: model.cameraBorderHex) },
            set: { model.setCameraBorderHex($0.hexString()) }
        ), supportsOpacity: false)
        .labelsHidden()
    }
}

extension Color {
    /// Parses "#RRGGBB" (or "RRGGBB"); falls back to white.
    init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0xFFFFFF
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    func hexString() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}
