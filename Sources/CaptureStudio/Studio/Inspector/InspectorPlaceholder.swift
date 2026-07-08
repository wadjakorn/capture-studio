import SwiftUI

/// Single source of truth for the small "Soon" pill used on disabled
/// placeholder controls.
@MainActor func soonBadge(_ note: String = "Soon") -> some View {
    Text(note)
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(.quaternary))
        .foregroundStyle(.secondary)
}

private struct ComingSoonModifier: ViewModifier {
    let note: String
    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            content
            soonBadge(note)
        }
        .disabled(true)
        .opacity(0.55)
        .help("Coming soon — not yet available")
    }
}

extension View {
    /// Render a control as a deliberate, disabled placeholder with a "Soon" tag.
    func comingSoon(_ note: String = "Soon") -> some View {
        modifier(ComingSoonModifier(note: note))
    }
}

/// THE standard inspector toggle row. All inspector toggles must use this
/// (or `placeholderToggleRow` for features that aren't available yet) so
/// every tab shares one layout: icon, then a label that WRAPS (never
/// truncates), then a fixed-width switch pinned to the right edge. This is
/// what keeps long labels — "Position on canvas", "Auto-wrap lines" — from
/// squeezing or misaligning the switch. Do not hand-roll a raw `Toggle` in
/// an inspector panel; add a case here instead if the layout ever needs to
/// change.
@MainActor func inspectorToggleRow(_ title: String, systemImage: String? = nil,
                                    isOn: Binding<Bool>) -> some View {
    HStack(alignment: .center, spacing: 8) {
        if let systemImage {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
        Text(title)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
    }
    .frame(maxWidth: .infinity)
}

/// A disabled toggle row rendered as a "Soon" placeholder — same layout as
/// `inspectorToggleRow`, but always off and tagged.
@MainActor func placeholderToggleRow(_ title: String, systemImage: String? = nil,
                                      note: String = "Soon") -> some View {
    HStack(alignment: .center, spacing: 8) {
        if let systemImage {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
        Text(title)
            .fixedSize(horizontal: false, vertical: true)
        soonBadge(note)
        Spacer(minLength: 8)
        Toggle("", isOn: .constant(false))
            .labelsHidden()
            .toggleStyle(.switch)
    }
    .frame(maxWidth: .infinity)
    .disabled(true)
    .opacity(0.55)
    .help("Coming soon — not yet available")
}

/// A disabled slider placeholder — label + "Soon" badge above a dimmed,
/// non-interactive slider *mock*. A real `Slider` bound to a `.constant`
/// segfaults on macOS (it recurses writing back through the read-only
/// binding), so placeholders draw a static track + knob instead of a live
/// control.
@MainActor func placeholderSliderRow(_ title: String, note: String = "Soon") -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            soonBadge(note)
            Spacer()
        }
        Capsule()
            .fill(.quaternary)
            .frame(maxWidth: .infinity)
            .frame(height: 4)
            .overlay(alignment: .center) {
                Circle()
                    .fill(.secondary)
                    .frame(width: 14, height: 14)
            }
            .frame(height: 14)
            .opacity(0.5)
    }
    .help("Coming soon — not yet available")
}

/// A disabled picker placeholder — label + "Soon" badge above a static
/// pop-up *mock* (a live `Picker` in a placeholder is unnecessary and, like
/// the slider, we avoid binding a real control here).
@MainActor func placeholderPickerRow(_ title: String, options: [String],
                                      note: String = "Soon") -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            soonBadge(note)
            Spacer()
        }
        HStack(spacing: 6) {
            Text(options.first ?? "").font(.caption)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 140, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        .foregroundStyle(.secondary)
        .opacity(0.6)
    }
    .help("Coming soon — not yet available")
}
