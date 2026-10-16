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

    @Test func caseOnlyRenameAllowed() async throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeProject("alpha", in: dir)
        let (model, _) = makeModel(dir: dir)
        await model.reloadAndWait()
        try model.rename(try #require(model.projects.first), to: "Alpha")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["Alpha.capturestudio"])
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
}
