import SwiftUI

/// Cursor appearance inspector — the "Cursor" rail tab. Mirrors the bottom
/// bar's `cursorControls`, plus placeholder rows for future cursor styling.
struct CursorInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cursor").font(.caption).foregroundStyle(.secondary)

                inspectorToggleRow("Show cursor", systemImage: "cursorarrow",
                                   isOn: Binding(get: { model.showCursor },
                                                 set: { model.setShowCursor($0) }))
                .help("Show the recorded cursor")

                inspectorToggleRow("Click feedback rings", systemImage: "cursorarrow.click",
                                   isOn: Binding(get: { model.clickFeedback },
                                                 set: { model.setClickFeedback($0) }))
                .help("Show click feedback rings")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance").font(.caption).foregroundStyle(.secondary)
                placeholderSliderRow("Size")
                placeholderSliderRow("Smoothing")
                placeholderPickerRow("Click style", options: ["Ring"])
            }
        }
        .padding(16)
    }
}
