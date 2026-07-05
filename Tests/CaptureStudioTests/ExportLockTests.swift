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
        // Without the lock, setTrimIn(5) with trimOut==0 clamps trimIn negative;
        // the guard must leave it untouched.
        let trimBefore = m.trimIn
        m.setTrimIn(5)
        #expect(m.trimIn == trimBefore)

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
}
