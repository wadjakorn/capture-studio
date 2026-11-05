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

    // MARK: - Undo / redo (EditHistory wired into saveEdit)

    @Test func splitIsOneUndoStep() {
        let m = model(); m.seek(to: 4); m.splitAtPlayhead()
        #expect(m.canUndo)
        m.undo()
        #expect(m.segments.isEmpty)
        #expect(m.canRedo)
        m.redo()
        #expect(m.segments.count == 2)
    }

    @Test func undoRestoresSegments() {
        let m = model(); m.seek(to: 3); m.trimStartAtPlayhead(); m.undo()
        #expect(m.segments.isEmpty)
        #expect(m.currentTime == 3)   // preview rebuild needs a player -> manual check
    }

    @Test func dragCoalescesIntoOneStep() {
        let m = model(); m.seek(to: 2); m.addTextBlock()
        let id = m.textBlocks[0].id; let b0 = m.textBlocks[0].begin
        m.moveTextBlock(id, toBegin: 3); m.moveTextBlock(id, toBegin: 4); m.commitTextEdit()
        m.undo()
        #expect(m.textBlocks[0].begin == b0)
    }

    @Test func selectionChangeIsNotAStep() {
        let m = model(); m.seek(to: 2); m.addTextBlock()
        let n = m.canUndo
        #expect(n)
        m.selectTextBlock(nil); m.selectTextBlock(m.textBlocks[0].id)
        m.undo()
        #expect(m.textBlocks.isEmpty)   // selectTextBlock calls saveEdit(); equality coalescing swallows it
    }

    @Test func newEditAfterUndoClearsRedo() {
        let m = model(); m.seek(to: 4); m.splitAtPlayhead()
        m.undo()
        #expect(m.canRedo)
        m.seek(to: 6); m.splitAtPlayhead()
        #expect(!m.canRedo)
    }

    @Test func undoDisabledWhileExporting() {
        let m = model(); m.seek(to: 4); m.splitAtPlayhead()
        m.beginExportLockForTests()
        #expect(!m.canUndo)
    }
}
