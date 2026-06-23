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

    @Test func writeAndDeleteSubtitleFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("input.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nHi".write(to: src, atomically: true, encoding: .utf8)

        let name = try bundle.writeSubtitleFile(from: src)
        #expect(name == "subtitles.srt")
        let dest = bundle.subtitleFileURL(name)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try String(contentsOf: dest, encoding: .utf8).contains("Hi"))

        bundle.deleteSubtitleFile()
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func writeSubtitleFileReplacesPrevious() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src1 = dir.appendingPathComponent("a.srt")
        try "first".write(to: src1, atomically: true, encoding: .utf8)
        _ = try bundle.writeSubtitleFile(from: src1)

        let src2 = dir.appendingPathComponent("b.srt")
        try "second".write(to: src2, atomically: true, encoding: .utf8)
        let name = try bundle.writeSubtitleFile(from: src2)
        #expect(try String(contentsOf: bundle.subtitleFileURL(name), encoding: .utf8) == "second")
    }
}
