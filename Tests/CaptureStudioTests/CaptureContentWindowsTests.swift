import Testing
@testable import CaptureStudio

@Suite struct CaptureContentWindowsTests {
    @Test func exceptsVisibleContentAndSheetsOnly() {
        let ids = CaptureFilterPolicy.exceptedWindowIDs(content: [
            .init(windowNumber: 10, isVisible: true,  isMiniaturized: false, sheetNumbers: [11]),
            .init(windowNumber: 20, isVisible: true,  isMiniaturized: true,  sheetNumbers: []),
            .init(windowNumber: 0,  isVisible: true,  isMiniaturized: false, sheetNumbers: []),
            .init(windowNumber: 30, isVisible: false, isMiniaturized: false, sheetNumbers: []),
        ], available: [10, 11, 20, 30])
        #expect(Set(ids) == [10, 11])
    }

    @Test func coalescerNeverLosesAnUpdate() {
        var c = RefreshCoalescer()
        #expect(c.request() == true)    // A starts
        #expect(c.request() == false)   // B arrives mid-flight → dirty
        #expect(c.finish() == true)     // A done → must run again for B
        #expect(c.finish() == false)    // rerun done, nothing pending
        #expect(c.request() == true)
    }

    @Test func dropsIDsScreenCaptureKitDoesNotKnow() {
        #expect(CaptureFilterPolicy.exceptedWindowIDs(content: [.init(windowNumber: 10, isVisible: true, isMiniaturized: false, sheetNumbers: [])], available: []).isEmpty)
    }

    /// A visible window (or its sheet) SCK hasn't listed yet is what triggers
    /// the one-shot retry; hidden/minimized/unnumbered ones never should.
    @Test func reportsVisibleWindowsMissingFromShareableContent() {
        let content: [ContentWindowInfo] = [
            .init(windowNumber: 10, isVisible: true,  isMiniaturized: false, sheetNumbers: [11]),
            .init(windowNumber: 30, isVisible: false, isMiniaturized: false, sheetNumbers: []),
            .init(windowNumber: 0,  isVisible: true,  isMiniaturized: false, sheetNumbers: []),
        ]
        #expect(CaptureFilterPolicy.hasUnlistedVisibleWindow(content: content, available: [10, 11]) == false)
        #expect(CaptureFilterPolicy.hasUnlistedVisibleWindow(content: content, available: [10]) == true)
        #expect(CaptureFilterPolicy.hasUnlistedVisibleWindow(content: content, available: [11]) == true)
    }
}
