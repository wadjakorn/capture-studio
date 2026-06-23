import SwiftUI

/// Bottom-most canvas input layer: a tap deselects everything; a left-drag pans
/// the zoomed inspection view (content follows the cursor), mirroring the
/// trackpad/middle-drag navigation in `CanvasEventCatcher`. It sits at the
/// bottom of the canvas ZStack, so block move/resize, pan-video, and
/// text-select all take priority — this only runs on empty canvas. Panning is a
/// no-op at fit zoom. Uses the global coordinate space so the inspection
/// transform doesn't feed back into the drag.
struct CanvasNavigationLayer: View {
    @ObservedObject var model: StudioModel
    @State private var lastTranslation: CGSize?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { model.deselectAll() }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        // First event sets the baseline (zero delta); later
                        // events pan by the per-update increment.
                        let previous = lastTranslation ?? value.translation
                        lastTranslation = value.translation
                        model.panCanvas(by: CGSize(width: value.translation.width - previous.width,
                                                   height: value.translation.height - previous.height))
                    }
                    .onEnded { _ in lastTranslation = nil }
            )
    }
}
