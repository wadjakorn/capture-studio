import Testing
import Foundation
@testable import CaptureStudio

@Suite struct StudioOpenEligibilityTests {
    /// A real bundle in a fresh tmp dir. `finalized` writes meta.json, which is
    /// the only thing `ProjectBundle.isFinalized` looks at.
    private func makeBundle(finalized: Bool) throws -> (bundle: ProjectBundle, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = try ProjectBundle.createNew(in: dir)
        if finalized {
            try Data("{}".utf8).write(to: bundle.metaURL)
        }
        return (bundle, dir)
    }

    @Test func holdsActiveBundleOnlyWhileSessionOwnsIt() {
        #expect(RecordingSession.State.recording(startedAt: .now).holdsActiveBundle)
        #expect(RecordingSession.State.arming.holdsActiveBundle)
        #expect(RecordingSession.State.armed.holdsActiveBundle)
        #expect(RecordingSession.State.preparing.holdsActiveBundle)
        #expect(RecordingSession.State.finishing.holdsActiveBundle)
        #expect(!RecordingSession.State.idle.holdsActiveBundle)
        #expect(!RecordingSession.State.failed("x").holdsActiveBundle)
    }

    @Test func activeRecordingIsBlocked() throws {
        let (bundle, dir) = try makeBundle(finalized: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Same bundle, spelled with a trailing slash — must still match.
        let active = URL(fileURLWithPath: bundle.url.path + "/")
        #expect(StudioOpenEligibility.evaluate(url: bundle.url, activeRecording: active) == .recordingInProgress)
    }

    @Test func activeRecordingWinsOverMissingMeta() throws {
        // A bundle mid-recording has no meta.json yet; the more specific
        // "in progress" answer must win over "incomplete".
        let (bundle, dir) = try makeBundle(finalized: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(StudioOpenEligibility.evaluate(url: bundle.url, activeRecording: bundle.url) == .recordingInProgress)
    }

    @Test func justFinishedRecordingIsOK() throws {
        // stop() flips state to .idle before auto-opening, so activeBundleURL
        // is nil by then — this pins that path open.
        let (bundle, dir) = try makeBundle(finalized: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(StudioOpenEligibility.evaluate(url: bundle.url, activeRecording: nil) == .ok)
    }

    @Test func otherActiveRecordingDoesNotBlock() throws {
        let (bundle, dir) = try makeBundle(finalized: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = dir.appendingPathComponent("Other.capturestudio", isDirectory: true)
        #expect(StudioOpenEligibility.evaluate(url: bundle.url, activeRecording: other) == .ok)
    }

    @Test func missingMetaIsNotFinalized() throws {
        let (bundle, dir) = try makeBundle(finalized: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(StudioOpenEligibility.evaluate(url: bundle.url, activeRecording: nil) == .notFinalized)
    }
}
