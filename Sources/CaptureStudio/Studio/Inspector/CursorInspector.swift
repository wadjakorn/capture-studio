import SwiftUI

/// Cursor appearance inspector — the "Cursor" rail tab. Mirrors the bottom
/// bar's `cursorControls`, plus placeholder rows for future cursor styling.
struct CursorInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cursor").font(.caption).foregroundStyle(.secondary)

                Toggle(isOn: Binding(get: { model.showCursor },
                                     set: { model.setShowCursor($0) })) {
                    Label("Show recorded cursor", systemImage: "cursorarrow")
                }
                .toggleStyle(.switch)
                .help("Show the recorded cursor")

                Toggle(isOn: Binding(get: { model.clickFeedback },
                                     set: { model.setClickFeedback($0) })) {
                    Label("Click feedback rings", systemImage: "cursorarrow.click")
                }
                .toggleStyle(.switch)
                .help("Show click feedback rings")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance").font(.caption).foregroundStyle(.secondary)
                styleSlider("Size", value: .constant(1.0), range: 0.5...2.0, model: model)
                    .comingSoon()
                styleSlider("Smoothing", value: .constant(0.0), range: 0...1, model: model)
                    .comingSoon()
                Picker("Click style", selection: .constant(0)) {
                    Text("Ring").tag(0)
                }
                .comingSoon()
            }
        }
        .padding(16)
    }
}
