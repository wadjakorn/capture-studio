import SwiftUI

/// Centered floating canvas toolbar: layout ("Auto") menu, Crop, and Mask.
/// Not yet wired into `StudioView` — Task 5 swaps the layout to use this.
struct StudioCanvasToolbar: View {
    @ObservedObject var model: StudioModel
    @Binding var activeTab: RailTab
    let maskAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(CameraLayout.allCases, id: \.self) { layout in
                    Button {
                        layoutBinding.wrappedValue = layout
                        activeTab = .camera
                    } label: {
                        if layoutBinding.wrappedValue == layout {
                            Label(layout.label, systemImage: "checkmark")
                        } else {
                            Text(layout.label)
                        }
                    }
                }
            } label: {
                Label(layoutBinding.wrappedValue.label, systemImage: "rectangle.3.offgrid")
            }
            .menuStyle(.button)
            .help("Frame layout for the selected layout block (or the home state)")

            Button {
                activeTab = .frame
            } label: {
                Label("Crop", systemImage: "crop")
            }
            .help("Open the Frame inspector")

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

    /// The layout the toolbar picker edits: the selected block's, else the
    /// home (empty-timeline / before-first-block) layout.
    private var layoutBinding: Binding<CameraLayout> {
        Binding(
            get: { model.selectedLayoutBlock?.layout ?? model.cameraHomeLayout },
            set: { newValue in
                if let id = model.selectedLayoutBlockID { model.setLayoutBlockLayout(id, newValue) }
                else { model.setHomeLayout(newValue) }
            })
    }
}
