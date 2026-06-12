import Testing
import Foundation
@testable import CaptureStudio

@Suite struct ProjectBundleTests {
    @Test func metaRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundle = try ProjectBundle.createNew(in: tmp, date: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(bundle.url.pathExtension == ProjectBundle.pathExtension)
        #expect(!bundle.isFinalized)

        let meta = ProjectMeta(
            app: AppInfo(version: "0.1.0", macOSVersion: "26.5.0"),
            display: DisplayInfo(
                displayID: 1, pixelWidth: 3456, pixelHeight: 2234,
                pointWidth: 1728, pointHeight: 1117, scaleFactor: 2,
                originX: 0, originY: 0
            ),
            tracks: [
                TrackInfo(
                    type: .screen, filename: "screen.mp4",
                    sessionStartHostTime: 12345.678,
                    nominalFPS: 60, codec: "h264",
                    deviceName: "Built-in Display", deviceID: "1"
                ),
                TrackInfo(
                    type: .systemAudio, filename: "system.m4a",
                    sessionStartHostTime: 12345.701,
                    nominalFPS: nil, codec: "aac",
                    deviceName: "System Audio", deviceID: nil
                )
            ],
            recordedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        try bundle.writeMeta(meta)
        #expect(bundle.isFinalized)

        let loaded = try bundle.loadMeta()
        #expect(loaded == meta)
        #expect(loaded.schemaVersion == 1)
    }

    @Test func bundleFileURLs() {
        let bundle = ProjectBundle(url: URL(fileURLWithPath: "/tmp/X.capturestudio"))
        #expect(bundle.screenURL.lastPathComponent == "screen.mp4")
        #expect(bundle.cameraURL.lastPathComponent == "camera.mp4")
        #expect(bundle.micURL.lastPathComponent == "mic.m4a")
        #expect(bundle.systemAudioURL.lastPathComponent == "system.m4a")
        #expect(bundle.eventsURL.lastPathComponent == "events.jsonl")
        #expect(bundle.editURL.lastPathComponent == "edit.json")
        #expect(bundle.metaURL.lastPathComponent == "meta.json")
    }
}
