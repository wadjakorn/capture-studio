import Testing
@testable import CaptureStudio

@Suite struct RailTabTests {
    private func sel(text: Bool = false, shape: Bool = false, zoom: Bool = false,
                     cameraMove: Bool = false, layout: Bool = false, subtitle: Bool = false)
    -> StudioSelectionSummary {
        StudioSelectionSummary(textSelected: text, shapeSelected: shape, zoomSelected: zoom,
                               cameraMoveSelected: cameraMove, layoutSelected: layout,
                               subtitleSelected: subtitle)
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
    @Test func textRoutesToCaptions() {
        #expect(InspectorContext.resolve(selection: sel(text: true), activeTab: .frame) == .tab(.captions))
    }
    @Test func subtitleRoutesToCaptions() {
        #expect(InspectorContext.resolve(selection: sel(subtitle: true), activeTab: .frame) == .tab(.captions))
    }
    @Test func cameraMoveRoutesToCamera() {
        #expect(InspectorContext.resolve(selection: sel(cameraMove: true), activeTab: .audio) == .tab(.camera))
    }
    @Test func layoutRoutesToCamera() {
        #expect(InspectorContext.resolve(selection: sel(layout: true), activeTab: .audio) == .tab(.camera))
    }
    @Test func sevenTabsExist() {
        #expect(RailTab.allCases.count == 7)
    }
}
