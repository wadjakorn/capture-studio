import Testing
import Foundation
@testable import CaptureStudio

/// The editor hard-locks while an export runs: mutating entry points no-op and
/// `cancelExport()` returns the model to `.idle` (unlocking the UI + close).
@MainActor
struct ExportLockTests {
    private func makeModel() -> StudioModel {
        StudioModel(bundleURL: URL(fileURLWithPath: "/tmp/export-lock-test.capturestudio"))
    }

    @Test func isExportingReflectsState() {
        let m = makeModel()
        #expect(!m.isExporting)
        m.beginExportLockForTests()
        #expect(m.isExporting)
    }

    @Test func mutatorsNoOpWhileExporting() {
        let m = makeModel()
        m.beginExportLockForTests()
        // The export guard must leave the edit model untouched.
        m.resetSegments()
        #expect(m.segments.isEmpty)

        let zoomBefore = m.canvasZoom
        m.zoomCanvas(by: 2)
        #expect(m.canvasZoom == zoomBefore)
    }

    @Test func cancelExportUnlocks() {
        let m = makeModel()
        m.beginExportLockForTests()
        #expect(m.isExporting)
        m.cancelExport()
        #expect(!m.isExporting)
        #expect(m.exportState == .idle)
    }

    @Test func cancelIsNoOpWhenIdle() {
        let m = makeModel()
        m.cancelExport()
        #expect(m.exportState == .idle)
    }

    @Test func togglePlayIsNoOpWhileExporting() {
        let m = makeModel()
        m.beginExportLockForTests()
        m.togglePlay()
        #expect(!m.isPlaying)
    }
}
