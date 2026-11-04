import Testing
@testable import CaptureStudio

@Suite struct CameraFormatChooserTests {
    @Test func prefers1080pOver4K() {
        let c = [CameraFormatCandidate(width: 3840, height: 2160, maxFPS: 30, index: 0),
                 CameraFormatCandidate(width: 1920, height: 1080, maxFPS: 30, index: 1)]
        #expect(CameraFormatChooser.best(c)?.index == 1)
    }
    @Test func tieBreaksOnFPS() {
        let c = [CameraFormatCandidate(width: 1280, height: 720, maxFPS: 30, index: 0),
                 CameraFormatCandidate(width: 1280, height: 720, maxFPS: 60, index: 1)]
        #expect(CameraFormatChooser.best(c)?.index == 1)
    }
    @Test func tieBreaksOnLowestIndex() {
        let c = [CameraFormatCandidate(width: 1280, height: 720, maxFPS: 30, index: 3),
                 CameraFormatCandidate(width: 1280, height: 720, maxFPS: 30, index: 2)]
        #expect(CameraFormatChooser.best(c)?.index == 2)
    }
    @Test func portraitEdgeLimit() {
        let c = [CameraFormatCandidate(width: 1080, height: 1920, maxFPS: 30, index: 0),
                 CameraFormatCandidate(width: 2160, height: 3840, maxFPS: 30, index: 1)]
        #expect(CameraFormatChooser.best(c)?.index == 0)
    }
    @Test func emptyIsNil() { #expect(CameraFormatChooser.best([]) == nil) }
}
