import Testing
import Foundation
@testable import CaptureStudio

@Suite struct ThumbnailStoreTests {
    private func tempBundle() throws -> (ProjectBundle, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (try ProjectBundle.createNew(in: tmp), tmp)
    }

    @Test func thumbnailURLIsInsideBundle() throws {
        let (bundle, tmp) = try tempBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(bundle.thumbnailURL.deletingLastPathComponent().standardizedFileURL
                == bundle.url.standardizedFileURL)
        #expect(bundle.thumbnailURL.lastPathComponent == "thumbnail.jpg")
    }

    @Test func thumbnailNameSurvivesBackgroundCleanup() throws {
        let (bundle, tmp) = try tempBundle()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data([0xFF, 0xD8]).write(to: bundle.thumbnailURL)
        let src = tmp.appendingPathComponent("bg.png")
        try Data([1, 2, 3]).write(to: src)
        _ = try bundle.writeBackgroundImage(from: src)
        bundle.deleteBackgroundImages()
        #expect(FileManager.default.fileExists(atPath: bundle.thumbnailURL.path))
    }

    @Test func failureIsCachedAndNotRetried() async throws {
        let (bundle, tmp) = try tempBundle()   // no screen.mp4
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ThumbnailStore()
        #expect(await store.image(bundleURL: bundle.url) == nil)
        #expect(await store.image(bundleURL: bundle.url) == nil)
        #expect(await store.generationCount == 1)
    }
}
