import Testing
import Foundation
@testable import CaptureStudio

@MainActor
struct StudioModelCutTests {
    func model() -> StudioModel {
        let m = StudioModel(bundleURL: URL(fileURLWithPath: "/tmp/cut-test.capturestudio"))
        m.loadForTests(duration: 10)
        return m
    }

    @Test func trimStartHidesHead() {
        let m = model(); m.seek(to: 3); m.trimStartAtPlayhead()
        #expect(TimelineSegments.cutRanges(m.segments) == [0..<3])
        #expect(m.currentTime == 3)
    }

    @Test func trimEndParksPlayheadOnLastVisibleFrame() {
        let m = model(); m.seek(to: 7); m.trimEndAtPlayhead()
        #expect(TimelineSegments.cutRanges(m.segments) == [7..<10])
        #expect(m.currentTime == 7)
    }

    @Test func trimStartAtZeroIsDisabled() {
        let m = model(); m.seek(to: 0)
        #expect(!m.canTrimStartAtPlayhead)
    }

    @Test func trimsAreNoOpWhileExporting() {
        let m = model(); m.seek(to: 3); m.beginExportLockForTests()
        m.trimStartAtPlayhead()
        #expect(m.segments.isEmpty)
    }

    @Test func visibleBoundsFollowTrims() {
        let m = model(); m.seek(to: 2); m.trimStartAtPlayhead()
        m.seek(to: 8); m.trimEndAtPlayhead()
        #expect(m.visibleBounds.start == 2)
        #expect(m.visibleBounds.end == 8)
    }
}
