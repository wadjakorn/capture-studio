import SwiftUI

/// Camera style panel — zoom, shape, aspect, corner radius, border, shadow.
struct CameraInspector: View {
    @ObservedObject var model: StudioModel

    /// The layout the picker edits: the selected block's, else the home
    /// (empty-timeline / before-first-block) layout.
    private var layoutBinding: Binding<CameraLayout> {
        Binding(
            get: { model.selectedLayoutBlock?.layout ?? model.cameraHomeLayout },
            set: { newValue in
                if let id = model.selectedLayoutBlockID { model.setLayoutBlockLayout(id, newValue) }
                else { model.setHomeLayout(newValue) }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Layout picker — picks the frame layout for the selected layout
            // block (or the home/default state when no layout block is selected).
            VStack(alignment: .leading, spacing: 2) {
                Text("Layout").font(.caption).foregroundStyle(.secondary)
                Picker("Layout", selection: layoutBinding) {
                    ForEach(CameraLayout.allCases, id: \.self) { layout in
                        Label(layout.label, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(model.selectedLayoutBlockID == nil)
                .help(model.selectedLayoutBlockID == nil
                      ? "Select a layout block to change its frame layout"
                      : "Frame layout for the selected layout block")
            }

            // Add / remove layout blocks — a layout block sets the frame
            // layout over a span; gaps render blank. Add is disabled when
            // the timeline is full.
            HStack(spacing: 8) {
                Button { model.addLayoutBlock() } label: {
                    Label("Add layout", systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(!model.canAddLayoutBlock)
                .help("Add a layout block at the playhead")

                Button {
                    if let id = model.selectedLayoutBlockID { model.removeLayoutBlock(id) }
                } label: {
                    Image(systemName: "rectangle.stack.badge.minus")
                }
                .disabled(model.selectedLayoutBlockID == nil)
                .help("Delete the selected layout block")
            }

            // Camera move keyframes — position/scale only; only meaningful
            // while the camera floats (main+float / float-camera) at the
            // playhead.
            HStack(spacing: 8) {
                Button { model.addBlock() } label: {
                    Label("Add move", systemImage: "plus.rectangle")
                }
                .disabled(!model.layoutAtPlayhead.cameraFloats)
                .help("Add a camera move block at the playhead")

                Button {
                    if let id = model.selectedBlockID { model.removeBlock(id) }
                } label: {
                    Image(systemName: "minus.rectangle")
                }
                .disabled(model.selectedBlockID == nil)
                .help("Delete the selected camera move block")
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Zoom").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.cameraZoom },
                                      set: { model.setCameraZoom($0) }),
                       in: 1.0...4.0) { editing in
                    if editing { model.beginStyleEdit() } else { model.endStyleEdit() }
                }
            }

            Picker("Shape", selection: Binding(
                get: { model.cameraShape },
                set: { model.setCameraShape($0) }
            )) {
                ForEach(CameraShape.allCases, id: \.self) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Button {
                    model.rotateCamera()
                } label: {
                    Label("Rotate", systemImage: "rotate.right")
                }
                .help("Rotate camera 90°")
                if model.cameraRotation != 0 {
                    Text("\(model.cameraRotation)°")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // Aspect only applies to rectangles; a circle is forced to 1:1.
            if model.cameraShape == .rectangle {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aspect").font(.caption).foregroundStyle(.secondary)
                    Picker("Aspect", selection: Binding(
                        get: { model.cameraAspect },
                        set: { model.setCameraAspect($0) }
                    )) {
                        ForEach(CameraAspect.allCases, id: \.self) { a in
                            Text(a.displayName).tag(a)
                        }
                    }
                    .labelsHidden()
                }

                styleSlider("Corner radius", value: Binding(
                    get: { model.cameraCornerRadius },
                    set: { model.setCameraCornerRadius($0) }
                ), range: 0...1, model: model)
            }

            styleSlider("Border", value: Binding(
                get: { model.cameraBorderWidth },
                set: { model.setCameraBorderWidth($0) }
            ), range: 0...0.1, model: model)

            if model.cameraBorderWidth > 0 {
                borderColorControls(model: model)
            }

            Toggle("Shadow", isOn: Binding(
                get: { model.cameraShadow },
                set: { model.setCameraShadow($0) }
            ))

            if model.cameraShadow {
                styleSlider("Shadow", value: Binding(
                    get: { model.cameraShadowRadius },
                    set: { model.setCameraShadowRadius($0) }
                ), range: 0...1, model: model)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
