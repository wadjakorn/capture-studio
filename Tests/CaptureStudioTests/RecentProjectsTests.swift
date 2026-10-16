import Testing
import Foundation
@testable import CaptureStudio

@Suite struct RecentProjectsTests {
    let a = URL(fileURLWithPath: "/tmp/A.capturestudio")
    let b = URL(fileURLWithPath: "/tmp/B.capturestudio")
    let c = URL(fileURLWithPath: "/tmp/C.capturestudio")

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func displayableDropsUnopenableKeepsOrder() {
        #expect(RecentProjects.displayable([a, b, c], excluding: nil, limit: 5, isOpenable: { $0 != b }) == [a, c])
    }
    @Test func displayableExcludesLastRecordedEvenWithTrailingSlash() {
        let aSlash = URL(fileURLWithPath: "/tmp/A.capturestudio/")
        #expect(RecentProjects.displayable([a, b], excluding: aSlash, limit: 5, isOpenable: { _ in true }) == [b])
    }
    @Test func displayableDedupesAndCaps() {
        #expect(RecentProjects.displayable([a, a, b, c], excluding: nil, limit: 2, isOpenable: { _ in true }) == [a, b])
    }
    @Test func unfinalizedBundleIsNotOpenable() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = try ProjectBundle.createNew(in: tmp)
        #expect(!RecentProjects.isOpenable(bundle.url))
        try Data("{}".utf8).write(to: bundle.metaURL)
        #expect(RecentProjects.isOpenable(bundle.url))
        // Wrong extension is never openable.
        #expect(!RecentProjects.isOpenable(tmp))
    }
    @Test func addingIsMRUDedupedCapped() {
        var list: [URL] = []
        for i in 0..<12 {
            list = RecentProjects.adding(URL(fileURLWithPath: "/tmp/P\(i).capturestudio"), to: list)
        }
        #expect(list.count == 10)
        #expect(list.first?.lastPathComponent == "P11.capturestudio")
        let p5 = URL(fileURLWithPath: "/tmp/P5.capturestudio")
        list = RecentProjects.adding(p5, to: list)
        #expect(list.count == 10)
        #expect(list.first == p5)
        #expect(list.filter { $0 == p5 }.count == 1)
    }

    @MainActor private func makeStore(_ defaults: UserDefaults, dir: URL) -> RecentProjectsStore {
        RecentProjectsStore(defaults: defaults, recordingsDirectory: dir, noteSystemRecent: { _ in })
    }

    @Test @MainActor func lastRecordedPersistsAcrossInstances() throws {
        let tmp = try tempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bundle = try ProjectBundle.createNew(in: tmp)
        try Data("{}".utf8).write(to: bundle.metaURL)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        makeStore(defaults, dir: tmp).noteRecorded(bundle.url)
        let reloaded = makeStore(defaults, dir: tmp)
        #expect(reloaded.lastRecorded?.standardizedFileURL.path == bundle.url.standardizedFileURL.path)
        #expect(reloaded.recent.count == 1)
    }
    @Test @MainActor func externalProjectTrackedOnlyOutsideRecordingsDir() {
        let dir = URL(fileURLWithPath: "/a/Capture Studio", isDirectory: true)
        let store = makeStore(UserDefaults(suiteName: UUID().uuidString)!, dir: dir)
        let inside = URL(fileURLWithPath: "/a/Capture Studio/x.capturestudio")
        let sibling = URL(fileURLWithPath: "/a/Capture Studio2/x.capturestudio")
        let elsewhere = URL(fileURLWithPath: "/b/y.capturestudio")
        store.noteOpened(inside)
        #expect(store.externalProjects.isEmpty)
        store.noteOpened(sibling)
        store.noteOpened(elsewhere)
        #expect(store.externalProjects == [elsewhere, sibling])
        #expect(store.recent.count == 3)
        store.clearRecents()
        #expect(store.recent.isEmpty)
        #expect(store.externalProjects.count == 2)
    }
    @Test @MainActor func replaceKeepsPositionInAllLists() {
        let dir = URL(fileURLWithPath: "/a/Capture Studio", isDirectory: true)
        let store = makeStore(UserDefaults(suiteName: UUID().uuidString)!, dir: dir)
        store.noteOpened(a); store.noteOpened(b); store.noteOpened(c)   // recent: c b a
        store.noteRecorded(b)                                            // recent: b c a
        let b2 = URL(fileURLWithPath: "/tmp/B2.capturestudio")
        store.replace(b, with: b2)
        #expect(store.recent == [b2, c, a])
        #expect(store.externalProjects == [b2, c, a])
        #expect(store.lastRecorded == b2)
    }
    @Test @MainActor func removeClearsLastRecordedWhenMatching() {
        let dir = URL(fileURLWithPath: "/a/Capture Studio", isDirectory: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = makeStore(defaults, dir: dir)
        store.noteRecorded(a)
        store.noteOpened(b)
        store.remove(b)
        #expect(store.lastRecorded == a)
        store.remove(URL(fileURLWithPath: "/tmp/A.capturestudio/"))
        #expect(store.lastRecorded == nil)
        #expect(store.recent.isEmpty)
        #expect(store.externalProjects.isEmpty)
        #expect(makeStore(defaults, dir: dir).lastRecorded == nil)
    }
}
