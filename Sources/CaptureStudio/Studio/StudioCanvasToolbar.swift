import SwiftUI

/// Centered floating canvas toolbar. Mask + Zoom — the two canvas actions no
/// rail tab covers: Mask drops a shape overlay at the playhead, Zoom drops an
/// auto zoom/pan block (its inspector is contextual, so this is the only way to
/// create the first block). (Crop was removed: it duplicated the Frame tab's
/// framing-window control. The old layout menu lives in the Camera tab.)
struct StudioCanvasToolbar: View {
    @ObservedObject var model: StudioModel
    let maskAction: () -> Void
    let zoomAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                maskAction()
            } label: {
                Label("Mask", systemImage: "square.on.circle")
            }
            .help("Add a shape overlay (rectangle / ellipse / blur) at the playhead")

            Button {
                zoomAction()
            } label: {
                Label("Zoom", systemImage: "plus.magnifyingglass")
            }
            .help("Add an auto zoom/pan block (follows the cursor) at the playhead")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}
