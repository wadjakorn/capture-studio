import Testing
import CoreGraphics
@testable import CaptureStudio

@Suite struct MainSourceTests {
    @Test func storageRoundTrip() {
        let c = MainSource.camera(uniqueID: "abc")
        #expect(MainSource(kind: c.storage.kind, id: c.storage.id) == c)
        let d = MainSource.display(7)
        #expect(MainSource(kind: d.storage.kind, id: d.storage.id) == d)
        #expect(MainSource(kind: "display", id: "x") == nil)
        #expect(MainSource(kind: "bogus", id: "1") == nil)
    }

    @Test func resolveReportsMissingDevice() {
        #expect(MainSource.camera(uniqueID: "a").resolve(cameraIDs: ["b"], displayIDs: [1]) == .cameraMissing)
        #expect(MainSource.camera(uniqueID: "a").resolve(cameraIDs: ["a"], displayIDs: []) == nil)
        #expect(MainSource.display(2).resolve(cameraIDs: [], displayIDs: [1]) == .displayMissing)
        #expect(MainSource.display(1).resolve(cameraIDs: [], displayIDs: [1]) == nil)
    }

    @Test func frontExcludesMainCamera() {
        #expect(RecorderSelection.frontCameraIDs(all: ["a", "b"], main: .camera(uniqueID: "a")) == ["b"])
        #expect(RecorderSelection.frontCameraIDs(all: ["a", "b"], main: .display(1)) == ["a", "b"])
        #expect(RecorderSelection.frontCameraIDs(all: ["c", "a", "b"], main: .camera(uniqueID: "a")) == ["c", "b"])
    }

    @Test func resolvedFrontDropsConflict() {
        #expect(RecorderSelection.resolvedFrontCamera("a", candidates: ["b"]) == nil)
        #expect(RecorderSelection.resolvedFrontCamera("b", candidates: ["b"]) == "b")
        #expect(RecorderSelection.resolvedFrontCamera(nil, candidates: ["b"]) == nil)
    }

    @Test func cameraMainDisablesScreenOnlyOptions() {
        let cam = MainSource.camera(uniqueID: "a")
        #expect(!RecorderSelection.systemAudioAllowed(for: cam))
        #expect(!RecorderSelection.areaAllowed(for: cam))
        #expect(!RecorderSelection.needsScreenPermission(for: cam))
        #expect(RecorderSelection.areaAllowed(for: .display(1)))
        #expect(RecorderSelection.needsScreenPermission(for: .display(1)))
    }
}
