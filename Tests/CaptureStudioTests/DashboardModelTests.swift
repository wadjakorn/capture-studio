import Foundation
import Testing
@testable import CaptureStudio

@MainActor
@Suite struct DashboardModelTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashmodel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeProject(_ name: String, in dir: URL, finalized: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent("\(name).capturestudio", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if finalized {
            let display = DisplayInfo(displayID: 1, pixelWidth: 200, pixelHeight: 200, pointWidth: 100,
                                      pointHeight: 100, scaleFactor: 2, originX: 0, originY: 0)
            let meta = ProjectMeta(app: AppInfo(version: "t", macOSVersion: "t"), display: display,
                                   tracks: [], recordedAt: Date())
            try ProjectBundle(url: url).writeMeta(meta)
        }
        return url
    }

    private func makeModel(dir: URL, locked: @escaping (URL) -> Bool = { _ in false },
                           active: URL? = nil) -> (DashboardModel, RecentProjectsStore) {
        let recents = RecentProjectsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                          recordingsDirectory: dir, noteSystemRecent: { _ in })
        let model = DashboardModel(directory: dir, recents: recents, isOpen: locked,
                                   activeRecording: { active })
        return (model, recents)
    }

    @Test func reloadLoadsProjects() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeProject("A", in: dir)
        let (model, _) = makeModel(dir: dir)
        await model.reloadAndWait()
        #expect(model.projects.map(\.name) == ["A"])
        model.query = "zzz"
        #expect(model.visible.isEmpty)
    }

    @Test func renameMovesAndUpdatesRecents() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject("A", in: dir)
        let (model, recents) = makeModel(dir: dir)
        await model.reloadAndWait()
        let project = try #require(model.projects.first)
        // Seed with the scanned spelling: /var vs /private/var differs in tmp.
        recents.noteOpened(project.url)
        try model.rename(project, to: "  B  ")
        let new = project.url.deletingLastPathComponent().appendingPathComponent("B.capturestudio")
        #expect(FileManager.default.fileExists(atPath: new.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(recents.recent.map { $0.standardizedFileURL.path } == [new.standardizedFileURL.path])
    }

    @Test func renameBlockedWhenLockedOrInvalid() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject("A", in: dir)
        _ = try makeProject("C", in: dir)
        let (model, _) = makeModel(dir: dir, locked: { _ in true })
        await model.reloadAndWait()
        let a = try #require(model.projects.first { $0.name == "A" })
        #expect(throws: DashboardError.self) { try model.rename(a, to: "B") }
        #expect(FileManager.default.fileExists(atPath: url.path))

        let (free, _) = makeModel(dir: dir)
        await free.reloadAndWait()
        #expect(throws: DashboardError.self) { try free.rename(a, to: "C") }
        #expect(throws: DashboardError.self) { try free.rename(a, to: "x/y") }
        #expect(throws: DashboardError.self) { try free.rename(a, to: " ") }
    }

    /// Case-only renames go through a temporary sibling (case-insensitive APFS
    /// can refuse a direct move as "file exists"); the end state must be the
    /// new casing with no temp leftover and recents following along.
    @Test func caseOnlyRenameAllowed() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeProject("alpha", in: dir)
        let (model, recents) = makeModel(dir: dir)
        await model.reloadAndWait()
        let project = try #require(model.projects.first)
        recents.noteOpened(project.url)
        try model.rename(project, to: "Alpha")
        // contentsOfDirectory(atPath:) includes dot-files, so a stranded
        // `.alpha-<uuid>.capturestudio` temp would show up here.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["Alpha.capturestudio"])
        #expect(recents.recent.map(\.lastPathComponent) == ["Alpha.capturestudio"])
    }

    @Test func caseOnlyRenameUsesTemporarySibling() {
        let parent = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let from = parent.appendingPathComponent("demo.capturestudio")
        let to = parent.appendingPathComponent("Demo.capturestudio")
        #expect(DashboardModel.isCaseOnlyRename(from: from, to: to))
        #expect(!DashboardModel.isCaseOnlyRename(from: from, to: parent.appendingPathComponent("Other.capturestudio")))
        #expect(!DashboardModel.isCaseOnlyRename(from: from, to: from))
        let temp = DashboardModel.temporarySibling(for: to)
        #expect(temp.deletingLastPathComponent() == parent)
        #expect(temp.lastPathComponent.hasPrefix(".Demo-"))
        #expect(temp.pathExtension == "capturestudio")
    }

    /// A copy that dies half-way must not leave a partial "A copy" behind
    /// (it would show up as a broken project). The injected copier creates
    /// the destination and then fails, deterministically.
    @Test func failedDuplicateLeavesNoPartialCopy() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeProject("A", in: dir)
        let recents = RecentProjectsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                          recordingsDirectory: dir, noteSystemRecent: { _ in })
        let model = DashboardModel(directory: dir, recents: recents, isOpen: { _ in false },
                                   activeRecording: { nil },
                                   copyItem: { _, destination in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: destination.appendingPathComponent("screen.mp4"))
            throw CocoaError(.fileReadNoPermission)
        })
        await model.reloadAndWait()
        let a = try #require(model.projects.first)
        await #expect(throws: CocoaError.self) { try await model.duplicate(a) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("A copy.capturestudio").path))
        #expect(model.busy.isEmpty)
    }

    /// While a project is being duplicated it is locked: rename/trash and a
    /// second duplicate are refused. The copier probes the model mid-copy by
    /// hopping to the main queue (idle: the test is suspended in `duplicate`)
    /// — no second cooperative-pool thread is ever waited on, so this can't
    /// deadlock however narrow the pool is.
    @Test func busyProjectIsLocked() async throws {
        final class Probe: @unchecked Sendable {
            weak var model: DashboardModel?
            var project: ProjectSummary?
            var busy = false, locked = false
            var renameError: DashboardError?, trashError: DashboardError?, duplicateError: DashboardError?
        }
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject("A", in: dir)
        let probe = Probe()
        let recents = RecentProjectsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                          recordingsDirectory: dir, noteSystemRecent: { _ in })
        let model = DashboardModel(directory: dir, recents: recents, isOpen: { _ in false },
                                   activeRecording: { nil },
                                   copyItem: { source, destination in
            let secondDone = DispatchSemaphore(value: 0)
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let model = probe.model, let a = probe.project else {
                        secondDone.signal(); return
                    }
                    probe.busy = model.busy.contains(a.id)
                    probe.locked = model.isLocked(a)
                    do { try model.rename(a, to: "B") } catch { probe.renameError = error as? DashboardError }
                    do { try model.moveToTrash(a) } catch { probe.trashError = error as? DashboardError }
                    // The busy guard throws before duplicate's first suspension,
                    // so this main-actor task finishes without the pool.
                    Task { @MainActor in
                        do { try await model.duplicate(a) } catch {
                            probe.duplicateError = error as? DashboardError
                        }
                        secondDone.signal()
                    }
                }
            }
            // Waits on a main-actor task only, never on another pool thread.
            secondDone.wait()
            try FileManager.default.copyItem(at: source, to: destination)
        })
        await model.reloadAndWait()
        let a = try #require(model.projects.first)
        #expect(!model.isLocked(a))
        probe.model = model
        probe.project = a

        try await model.duplicate(a)

        #expect(probe.busy)
        #expect(probe.locked)
        #expect(probe.renameError == .busy)
        #expect(probe.trashError == .busy)
        #expect(probe.duplicateError == .busy)
        #expect(!model.isLocked(a))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(model.projects.contains { $0.name == "A copy" })
        #expect(model.projects.count == 2)
    }

    @Test func duplicateCreatesCopyAndRefusesNonReady() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeProject("A", in: dir)
        _ = try makeProject("Broken", in: dir, finalized: false)
        let (model, _) = makeModel(dir: dir)
        await model.reloadAndWait()
        let a = try #require(model.projects.first { $0.name == "A" })
        try await model.duplicate(a)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("A copy.capturestudio").path))
        #expect(model.busy.isEmpty)
        #expect(model.projects.contains { $0.name == "A copy" })
        let broken = try #require(model.projects.first { $0.name == "Broken" })
        await #expect(throws: DashboardError.self) { try await model.duplicate(broken) }
    }

    @Test func trashRefusedWhenLockedOrRecording() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject("A", in: dir)
        let (locked, _) = makeModel(dir: dir, locked: { _ in true })
        await locked.reloadAndWait()
        let a = try #require(locked.projects.first)
        #expect(throws: DashboardError.self) { try locked.moveToTrash(a) }
        #expect(FileManager.default.fileExists(atPath: url.path))

        let (rec, _) = makeModel(dir: dir, active: url)
        await rec.reloadAndWait()
        let r = try #require(rec.projects.first)
        #expect(r.status == .recording)
        #expect(rec.isLocked(r))
        #expect(throws: DashboardError.self) { try rec.moveToTrash(r) }
    }

    @Test func removeFromLibraryOnlyForExternal() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try makeDir(); defer { try? FileManager.default.removeItem(at: ext) }
        let inside = try makeProject("In", in: dir)
        let outside = try makeProject("Out", in: ext)
        let (model, recents) = makeModel(dir: dir)
        recents.noteOpened(inside)
        recents.noteOpened(outside)
        await model.reloadAndWait()
        let i = try #require(model.projects.first { $0.name == "In" })
        let o = try #require(model.projects.first { $0.name == "Out" })
        model.removeFromLibrary(i)
        #expect(recents.recent.count == 2)
        model.removeFromLibrary(o)
        #expect(recents.externalProjects.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func duplicateExternalRegistersCopy() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try makeDir(); defer { try? FileManager.default.removeItem(at: ext) }
        let outside = try makeProject("Out", in: ext)
        let (model, recents) = makeModel(dir: dir)
        recents.noteOpened(outside)
        await model.reloadAndWait()
        let o = try #require(model.projects.first)
        try await model.duplicate(o)
        let copy = try #require(model.projects.first { $0.name == "Out copy" })
        #expect(copy.isExternal)
    }

    @Test func liveActiveRecordingLocksReadySnapshot() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject("A", in: dir)
        var active: URL?
        let recents = RecentProjectsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                          recordingsDirectory: dir, noteSystemRecent: { _ in })
        let model = DashboardModel(directory: dir, recents: recents, isOpen: { _ in false },
                                   activeRecording: { active })
        await model.reloadAndWait()
        let a = try #require(model.projects.first)
        #expect(a.status == .ready)
        #expect(!model.isLocked(a))
        active = url
        #expect(model.isLocked(a))
    }

    @Test func duplicateRefusedWhileLiveRecording() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject("A", in: dir)
        var active: URL?
        let recents = RecentProjectsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                          recordingsDirectory: dir, noteSystemRecent: { _ in })
        let model = DashboardModel(directory: dir, recents: recents, isOpen: { _ in false },
                                   activeRecording: { active })
        await model.reloadAndWait()
        let a = try #require(model.projects.first)
        #expect(a.status == .ready)
        active = url
        await #expect(throws: DashboardError.self) { try await model.duplicate(a) }
        await model.reloadAndWait()
        #expect(model.projects.count == 1)
    }

    @Test func renameToSameNameIsNoOp() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeProject("A", in: dir)
        let (model, _) = makeModel(dir: dir)
        await model.reloadAndWait()
        let a = try #require(model.projects.first)
        try model.rename(a, to: " A ")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
