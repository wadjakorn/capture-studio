import SwiftUI

private struct ComingSoonModifier: ViewModifier {
    let note: String
    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            content
            Text(note)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
                .foregroundStyle(.secondary)
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
