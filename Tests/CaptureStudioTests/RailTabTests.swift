import Testing
@testable import CaptureStudio

@Suite struct RailTabTests {
    private func sel(text: Bool = false, shape: Bool = false, zoom: Bool = false,
                     cameraMove: Bool = false, layout: Bool = false, subtitle: Bool = false,
                     camera: Bool = false)
    -> StudioSelectionSummary {
        StudioSelectionSummary(textSelected: text, shapeSelected: shape, zoomSelected: zoom,
                               cameraMoveSelected: cameraMove, layoutSelected: layout,
                               subtitleSelected: subtitle, cameraSelected: camera)
    }

    @Test func nothingSelectedShowsActiveTab() {
        #expect(InspectorContext.resolve(selection: sel(), activeTab: .audio) == .tab(.audio))
    }
    @Test func shapeSelectionIsContextual() {
        #expect(InspectorContext.resolve(selection: sel(shape: true), activeTab: .frame) == .shape)
    }
    @Test func zoomSelectionIsContextual() {
        #expect(InspectorContext.resolve(selection: sel(zoom: true), activeTab: .frame) == .zoom)
    }
    @Test func textRoutesToTextTab() {
        #expect(InspectorContext.resolve(selection: sel(text: true), activeTab: .frame) == .tab(.text))
    }
    @Test func subtitleRoutesToSubtitlesTab() {
        #expect(InspectorContext.resolve(selection: sel(subtitle: true), activeTab: .frame) == .tab(.subtitles))
    }
    @Test func cameraMoveRoutesToCamera() {
        #expect(InspectorContext.resolve(selection: sel(cameraMove: true), activeTab: .audio) == .tab(.camera))
    }
    @Test func layoutRoutesToCamera() {
        #expect(InspectorContext.resolve(selection: sel(layout: true), activeTab: .audio) == .tab(.camera))
    }
    @Test func cameraSelectionRoutesToCamera() {
        #expect(InspectorContext.resolve(selection: sel(camera: true), activeTab: .audio) == .tab(.camera))
    }
    @Test func sixTabsExist() {
        #expect(RailTab.allCases.count == 6)
    }
}
