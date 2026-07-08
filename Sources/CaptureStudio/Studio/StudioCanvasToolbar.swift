import SwiftUI

/// Centered floating canvas toolbar. Just Mask now — it drops a shape overlay
/// at the playhead, the one canvas action no rail tab covers. (Crop was
/// removed: it duplicated the Frame tab's framing-window control. The old
/// layout menu was removed too: that lives in the Camera tab.)
struct StudioCanvasToolbar: View {
    @ObservedObject var model: StudioModel
    let maskAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                maskAction()
            } label: {
                Label("Mask", systemImage: "square.on.circle")
            }
            .help("Add a shape overlay (rectangle / ellipse / blur) at the playhead")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}
