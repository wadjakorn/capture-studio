import SwiftUI

/// Per-block zoom controls (scale + follow sensitivity + overflow) — operates
/// on the selected move/zoom block.
struct ZoomInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Add / delete — add is also available via the timeline zoom
            // lane; this button is a convenient duplicate.
            HStack(spacing: 8) {
                Button { model.addZoomBlock() } label: {
                    Label("Add zoom", systemImage: "plus.magnifyingglass")
                }
                .help("Add an auto zoom/pan block at the playhead")

                Button(role: .destructive) {
                    if let id = model.selectedZoomBlockID { model.removeZoomBlock(id) }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.selectedZoomBlockID == nil)
                .help("Delete the selected zoom block")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f×", model.selectedZoomScale))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { model.selectedZoomScale },
                                   set: { model.setZoomScale($0) }),
                    in: 1...6,
                    onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Follow sensitivity", systemImage: "hand.draw")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((model.selectedZoomSensitivity * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { model.selectedZoomSensitivity },
                                   set: { model.setZoomSensitivity($0) }),
                    in: 0...1,
                    onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
                )
                Text("How aggressively the zoom pans toward the cursor — low = calm, high = snappy.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { model.selectedZoomOverflow },
                                     set: { model.setZoomOverflow($0) })) {
                    Label("Overflow inside frame", systemImage: "rectangle.expand.vertical")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                Text("Let the pan run past the video edge so the background shows inside the frame at the edges (cursor stays centred in the frame). Off keeps the video filling the frame. The video is always clipped to the frame either way.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
