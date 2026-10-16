import Testing
import Foundation
@testable import CaptureStudio

@Suite struct ProjectLibraryTests {
    private func makeTmp() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func meta(at date: Date, camera: Bool = false) -> ProjectMeta {
        var tracks = [TrackInfo(type: .screen, filename: "screen.mp4", sessionStartHostTime: 1,
                                nominalFPS: 60, codec: "h264", deviceName: "D", deviceID: "1")]
        if camera {
            tracks.append(TrackInfo(type: .camera, filename: "camera.mp4", sessionStartHostTime: 1,
                                    nominalFPS: 30, codec: "h264", deviceName: "C", deviceID: "2"))
        }
        return ProjectMeta(
            app: AppInfo(version: "0", macOSVersion: "15.0.0"),
            display: DisplayInfo(displayID: 1, pixelWidth: 100, pixelHeight: 100,
                                 pointWidth: 100, pointHeight: 100, scaleFactor: 1,
                                 originX: 0, originY: 0),
            tracks: tracks, recordedAt: date)
    }

    @discardableResult
    private func makeBundle(_ name: String, in dir: URL, meta m: ProjectMeta?) throws -> ProjectBundle {
        let url = dir.appendingPathComponent("\(name).capturestudio", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = ProjectBundle(url: url)
        try Data(count: 10).write(to: bundle.screenURL)
        if let m { try bundle.writeMeta(m) }
        return bundle
    }

    private func summary(_ name: String, at date: Date? = nil, size: Int64 = 0) -> ProjectSummary {
        ProjectSummary(url: URL(fileURLWithPath: "/tmp/\(name).capturestudio"), name: name,
                       recordedAt: date, status: .ready, hasCamera: false,
                       byteSize: size, isExternal: false)
    }

    @Test func scanClassifiesStatus() throws {
        let dir = try makeTmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeBundle("a", in: dir, meta: meta(at: Date(), camera: true))
        try makeBundle("b", in: dir, meta: nil)
        let active = try makeBundle("c", in: dir, meta: nil)
        let bad = try makeBundle("d", in: dir, meta: nil)
        try Data("garbage".utf8).write(to: bad.metaURL)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("export"), withIntermediateDirectories: true)

        let result = ProjectLibrary.scan(directory: dir, extra: [], activeRecording: active.url)
        let byName = Dictionary(uniqueKeysWithValues: result.map { ($0.name, $0) })
        #expect(result.count == 4)
        #expect(byName["a"]?.status == .ready)
        #expect(byName["a"]?.hasCamera == true)
        #expect(byName["a"]?.byteSize ?? 0 >= 10)
        #expect(byName["b"]?.status == .incomplete)
        #expect(byName["c"]?.status == .recording)
        #expect(byName["d"]?.status == .unreadable)
        #expect(result.allSatisfy { !$0.isExternal })
    }

    @Test func scanMergesExternalRecentsWithoutDuplicates() throws {
        let dir = try makeTmp(), other = try makeTmp()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: other) }
        let inDir = try makeBundle("a", in: dir, meta: meta(at: Date()))
        let ext = try makeBundle("x", in: other, meta: meta(at: Date()))

        let result = ProjectLibrary.scan(directory: dir, extra: [inDir.url, ext.url, ext.url],
                                         activeRecording: nil)
        #expect(result.count == 2)
        #expect(result.first { $0.name == "a" }?.isExternal == false)
        #expect(result.first { $0.name == "x" }?.isExternal == true)
    }

    @Test func scanSkipsMissingExtraAndMissingDirectory() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ghost = missing.appendingPathComponent("g.capturestudio")
        #expect(ProjectLibrary.scan(directory: missing, extra: [ghost], activeRecording: nil).isEmpty)
    }

    @Test func sortOrders() {
        let old = summary("b2", at: Date(timeIntervalSince1970: 100), size: 5)
        let new = summary("b10", at: Date(timeIntervalSince1970: 200), size: 50)
        let undated = summary("a", size: 1)
        let all = [undated, old, new]
        #expect(ProjectLibrary.sorted(all, by: .newest).map(\.name) == ["b10", "b2", "a"])
        #expect(ProjectLibrary.sorted(all, by: .oldest).map(\.name) == ["b2", "b10", "a"])
        #expect(ProjectLibrary.sorted(all, by: .name).map(\.name) == ["a", "b2", "b10"])
        #expect(ProjectLibrary.sorted(all, by: .size).map(\.name) == ["b10", "b2", "a"])
    }

    @Test func filterIsCaseAndDiacriticInsensitive() {
        let items = [summary("Café Demo"), summary("Other")]
        #expect(ProjectLibrary.filtered(items, query: "cafe").map(\.name) == ["Café Demo"])
        #expect(ProjectLibrary.filtered(items, query: "DEMO").count == 1)
        #expect(ProjectLibrary.filtered(items, query: "  ").count == 2)
    }

    @Test func groupsByDayBoundaries() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_750_000_000) // 2025-06-15 15:06 UTC
        let items = [
            summary("today", at: now.addingTimeInterval(-3600)),
            summary("week", at: now.addingTimeInterval(-3 * 86400)),
            summary("earlier", at: now.addingTimeInterval(-30 * 86400)),
            summary("nodate"),
        ]
        let groups = ProjectLibrary.grouped(items, now: now, calendar: cal)
        #expect(groups.map(\.title) == ["Today", "This Week", "Earlier"])
        #expect(groups[0].items.map(\.name) == ["today"])
        #expect(groups[1].items.map(\.name) == ["week"])
        #expect(groups[2].items.map(\.name) == ["earlier", "nodate"])
        #expect(ProjectLibrary.grouped([summary("x", at: now)], now: now, calendar: cal).count == 1)
    }

    @Test func renameValidation() {
        #expect(ProjectLibrary.validateRename("  ", existing: []) == .empty)
        #expect(ProjectLibrary.validateRename("a/b", existing: []) == .invalidCharacters)
        #expect(ProjectLibrary.validateRename("a:b", existing: []) == .invalidCharacters)
        #expect(ProjectLibrary.validateRename(".hidden", existing: []) == .invalidCharacters)
        #expect(ProjectLibrary.validateRename("A", existing: ["a"]) == .duplicate)
        #expect(ProjectLibrary.validateRename("New", existing: ["a"]) == nil)
    }

    @Test func duplicateNameSkipsTaken() {
        #expect(ProjectLibrary.duplicateName(for: "X", existing: []) == "X copy")
        #expect(ProjectLibrary.duplicateName(for: "X", existing: ["X", "X copy"]) == "X copy 2")
        #expect(ProjectLibrary.duplicateName(for: "X", existing: ["X copy", "X copy 2"]) == "X copy 3")
    }

    @Test func duplicateNameIsCaseInsensitive() {
        #expect(ProjectLibrary.duplicateName(for: "X", existing: ["x copy"]) == "X copy 2")
    }

    @Test func sortTiesBreakById() {
        let d = Date(timeIntervalSince1970: 100)
        let a = summary("same", at: d, size: 5), b = summary("same", at: d, size: 5)
        let c = summary("zz", at: d, size: 5)
        for sort in [ProjectSort.newest, .oldest, .name, .size] {
            let one = ProjectLibrary.sorted([c, b, a], by: sort).map(\.id)
            let two = ProjectLibrary.sorted([a, c, b], by: sort).map(\.id)
            #expect(one == two)
        }
    }

    @Test func activeRecordingFallsBackToCreationDate() throws {
        let dir = try makeTmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let active = try makeBundle("live", in: dir, meta: nil)
        let result = ProjectLibrary.scan(directory: dir, extra: [], activeRecording: active.url)
        let item = try #require(result.first)
        let date = try #require(item.recordedAt)
        #expect(item.status == .recording)
        let groups = ProjectLibrary.grouped(result, now: date)
        #expect(groups.map(\.title) == ["Today"])
    }
}

/// Studio window re-focus must use the same resolved identity as `isOpen`,
/// or a symlinked spelling of an open bundle opens a second window for it.
@Suite struct StudioWindowIdentityTests {
    @Test func symlinkedSpellingMatchesOpenWindow() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let real = tmp.appendingPathComponent("A.capturestudio", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("Link.capturestudio")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Window identifier is the standardized path of whatever spelling opened it.
        let windowID = real.standardizedFileURL.path
        #expect(StudioLauncher.windowIdentifier(windowID, matches: link))
        #expect(StudioLauncher.windowIdentifier(link.standardizedFileURL.path, matches: real))
        #expect(StudioLauncher.windowIdentifier(windowID + "/", matches: real))
        #expect(!StudioLauncher.windowIdentifier(windowID, matches: tmp.appendingPathComponent("B.capturestudio")))
    }
}
