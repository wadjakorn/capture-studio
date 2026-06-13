import Testing
import Foundation
@testable import CaptureStudio

@Suite struct EditStateTests {
    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(trimIn: 1.5, trimOut: 8.25)
        try bundle.writeEdit(edit)
        #expect(bundle.loadEdit() == edit)
    }

    @Test func missingEditFileYieldsDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = bundle.loadEdit()
        #expect(edit.trimIn == 0)
        #expect(edit.trimOut == nil)
    }

    @Test func volumesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(micVolume: 0.4, systemVolume: 0.75)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.micVolume == 0.4)
        #expect(loaded.systemVolume == 0.75)
    }

    @Test func legacyEditJSONDefaultsVolumesToFull() throws {
        // edit.json written before volume fields existed.
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.micVolume == 1.0)
        #expect(edit.systemVolume == 1.0)
        #expect(edit.trimIn == 2.0)
    }

    @Test func cameraReframeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(cameraZoom: 2.5, cameraFeedX: 0.3, cameraFeedY: 0.7)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.cameraZoom == 2.5)
        #expect(loaded.cameraFeedX == 0.3)
        #expect(loaded.cameraFeedY == 0.7)
    }

    @Test func legacyEditJSONDefaultsCameraReframe() throws {
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraZoom == 1.0)
        #expect(edit.cameraFeedX == 0.5)
        #expect(edit.cameraFeedY == 0.5)
    }

    @Test func cameraStyleRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(cameraShape: .circle, cameraCornerRadius: 0.3,
                             cameraBorderWidth: 0.04, cameraBorderHex: "#FF8800",
                             cameraShadow: true)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.cameraShape == .circle)
        #expect(loaded.cameraCornerRadius == 0.3)
        #expect(loaded.cameraBorderWidth == 0.04)
        #expect(loaded.cameraBorderHex == "#FF8800")
        #expect(loaded.cameraShadow == true)
    }

    @Test func legacyEditJSONDefaultsCameraStyle() throws {
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraShape == .rectangle)
        #expect(edit.cameraCornerRadius == 0)
        #expect(edit.cameraBorderWidth == 0)
        #expect(edit.cameraBorderHex == "#FFFFFF")
        #expect(edit.cameraShadow == false)
    }

    @Test func unknownCameraShapeFallsBackToRectangle() throws {
        let json = #"{"schemaVersion":1,"cameraShape":"hexagon"}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraShape == .rectangle)
    }

    @Test func cameraAspectAndShadowRadiusRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(cameraShadowRadius: 0.8, cameraAspect: .threeByFour)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.cameraShadowRadius == 0.8)
        #expect(loaded.cameraAspect == .threeByFour)
    }

    @Test func cameraRotationRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(cameraRotation: 270)
        try bundle.writeEdit(edit)
        #expect(bundle.loadEdit().cameraRotation == 270)
    }

    @Test func legacyEditJSONDefaultsCameraAspectAndShadowRadius() throws {
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraAspect == .original)
        #expect(edit.cameraShadowRadius == 0.5)
        #expect(edit.cameraRotation == 0)
    }

    @Test func unknownCameraAspectFallsBackToOriginal() throws {
        let json = #"{"schemaVersion":1,"cameraAspect":"21:9"}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraAspect == .original)
    }

    @Test func cropRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(cropAspect: .nineBySixteen, cropCenterX: 0.3,
                             cropCenterY: 0.6, cropZoom: 0.5)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.cropAspect == .nineBySixteen)
        #expect(loaded.cropCenterX == 0.3)
        #expect(loaded.cropCenterY == 0.6)
        #expect(loaded.cropZoom == 0.5)
    }

    @Test func legacyEditJSONDefaultsToNoCrop() throws {
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cropAspect == .original)
        #expect(edit.cropCenterX == 0.5)
        #expect(edit.cropCenterY == 0.5)
        #expect(edit.cropZoom == 1.0)
    }

    @Test func unknownCropAspectFallsBackToOriginal() throws {
        let json = #"{"schemaVersion":1,"cropAspect":"21:9"}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cropAspect == .original)
    }

    @Test func wideAspectsDecode() throws {
        for raw in ["16:9", "4:3"] {
            let json = #"{"schemaVersion":1,"cropAspect":""# + raw + #""}"#
            let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
            #expect(edit.cropAspect.rawValue == raw)
            #expect(edit.cropAspect.ratio! > 1)
        }
    }

    @Test func cropAspectEncodesAsRawString() throws {
        let data = try JSONEncoder().encode(EditState(cropAspect: .square))
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains(#""cropAspect":"1:1""#))
    }

    @Test func nilTrimOutMeansFullLength() throws {
        let data = try JSONEncoder().encode(EditState(trimIn: 0, trimOut: nil))
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("trimOut"))
    }
}
