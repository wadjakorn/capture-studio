import SwiftUI

/// The "Shortcuts" rail tab — entirely placeholder (no model needed): a
/// key-overlay preview mock plus an enable toggle, all marked coming soon.
struct ShortcutsInspector: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(["⌘", "⇧", "S"], id: \.self) { key in
                        Text(key)
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 28, minHeight: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
                .comingSoon()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Options").font(.caption).foregroundStyle(.secondary)
                placeholderToggleRow("Show keystrokes on screen")
                Picker("Position", selection: .constant(0)) {
                    Text("Bottom center").tag(0)
                }
                .comingSoon()
            }
        }
        .padding(16)
    }
}
