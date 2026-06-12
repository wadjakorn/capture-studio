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

    @Test func nilTrimOutMeansFullLength() throws {
        let data = try JSONEncoder().encode(EditState(trimIn: 0, trimOut: nil))
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("trimOut"))
    }
}
