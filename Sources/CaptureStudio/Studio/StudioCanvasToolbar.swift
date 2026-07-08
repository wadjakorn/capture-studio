import SwiftUI

/// Centered floating canvas toolbar of *modal canvas tools*: Crop (drag the
/// framing window's handles on the video) and Mask (drop a shape overlay at
/// the playhead). These act on the canvas directly — they are not tab-openers.
/// The old layout ("Main Only") menu was removed: that control lives in the
/// Camera tab.
struct StudioCanvasToolbar: View {
    @ObservedObject var model: StudioModel
    @Binding var activeTab: RailTab
    let maskAction: () -> Void

    /// Crop is "on" while the framing window is enabled and showing its
    /// on-canvas transform handles.
    private var cropActive: Bool { model.frameEnabled && model.frameEditMode }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                toggleCrop()
            } label: {
                Label("Crop", systemImage: "crop")
            }
            .background(cropActive ? Color.accentColor.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .help("Crop the frame — drag the handles on the video")

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

    /// Toggle the on-canvas crop handles. Off→on enables the framing window
    /// (which enters edit mode) and opens the Frame tab so its size/aspect
    /// controls are at hand; on→off just hides the handles, keeping the crop.
    private func toggleCrop() {
        if cropActive {
            model.frameEditMode = false          // hide handles, keep the crop
            return
        }
        if model.frameEnabled {
            model.frameEditMode = true           // re-show handles
        } else {
            model.setFrameEnabled(true)          // enable frame + enter edit mode
        }
        // Now active → surface the Frame tab's size/aspect controls.
        model.deselectAll()
        activeTab = .frame
    }
}
