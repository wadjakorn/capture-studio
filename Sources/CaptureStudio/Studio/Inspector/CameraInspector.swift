import SwiftUI

/// Camera style panel — zoom, shape, aspect, corner radius, border, shadow.
struct CameraInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .frame(width: 240)
    }
}
