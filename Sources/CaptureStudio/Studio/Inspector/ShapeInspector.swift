import SwiftUI

/// Shape overlay style panel — kind, blur/fill/outline, corner radius.
struct ShapeInspector: View {
    @ObservedObject var model: StudioModel
    @State private var shapePopoverHeight: CGFloat = 0

    var body: some View {
        let block = model.selectedShapeBlock
        let kind = block?.kind ?? .rectangle
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Z-order + delete for the selected block — always shown,
                // disabled until a block is selected. (Add is via the Mask
                // canvas tool, not here.)
                HStack(spacing: 8) {
                    Button {
                        if let id = model.selectedShapeBlockID { model.sendShapeBackward(id) }
                    } label: { Image(systemName: "arrow.down.square") }
                        .disabled(block == nil)
                        .help("Send backward")
                    Button {
                        if let id = model.selectedShapeBlockID { model.bringShapeForward(id) }
                    } label: { Image(systemName: "arrow.up.square") }
                        .disabled(block == nil)
                        .help("Bring forward")
                    Button(role: .destructive) {
                        if let id = model.selectedShapeBlockID { model.removeShapeBlock(id) }
                    } label: { Image(systemName: "trash") }
                        .disabled(block == nil)
                        .help("Delete this shape block")
                }

                Divider()

                Picker("Kind", selection: Binding(
                    get: { kind },
                    set: { model.setShapeKind($0) }
                )) {
                    ForEach(ShapeKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                if kind == .blur {
                    Picker("Blur style", selection: Binding(
                        get: { block?.blurStyle ?? .gaussian },
                        set: { model.setShapeBlurStyle($0) }
                    )) {
                        ForEach(ShapeBlurStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    styleSliderText("Strength", value: Binding(
                        get: { block?.blurStrength ?? 0.04 },
                        set: { model.setShapeBlurStrength($0) }
                    ), range: 0.005...0.2, model: model)
                } else {
                    styleSliderText("Fill opacity", value: Binding(
                        get: { block?.fillOpacity ?? 0 },
                        set: { model.setShapeFillOpacity($0) }
                    ), range: 0...1, model: model)
                    if (block?.fillOpacity ?? 0) > 0 {
                        textColorRow("Fill color", hex: block?.fillHex ?? "#000000") {
                            model.setShapeFillHex($0)
                        }
                    }

                    styleSliderText("Outline", value: Binding(
                        get: { block?.strokeWidth ?? 0 },
                        set: { model.setShapeStrokeWidth($0) }
                    ), range: 0...0.1, model: model)
                    if (block?.strokeWidth ?? 0) > 0 {
                        textColorRow("Outline color", hex: block?.strokeHex ?? "#FF3B30") {
                            model.setShapeStrokeHex($0)
                        }
                    }

                    if kind == .rectangle {
                        styleSliderText("Corner radius", value: Binding(
                            get: { block?.cornerRadius ?? 0 },
                            set: { model.setShapeCornerRadius($0) }
                        ), range: 0...0.5, model: model)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .background(GeometryReader { g in
                Color.clear.preference(key: StylePopoverHeightKey.self, value: g.size.height)
            })
        }
        .frame(width: 320, height: min(shapePopoverHeight == 0 ? 320 : shapePopoverHeight, 500))
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(StylePopoverHeightKey.self) { shapePopoverHeight = $0 }
    }
}
