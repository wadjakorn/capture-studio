import AppKit

/// Our own record of recently opened projects. UserDefaults (paths) is the
/// source of truth rather than `NSDocumentController.recentDocumentURLs`,
/// which is capped by a system setting, drops unresolvable entries and can't
/// be tested. The system list is still fed as a side effect for Dock
/// "Open Recent". Entries that can't be opened are filtered at display time.
@MainActor
final class RecentProjectsStore: ObservableObject {
    static let shared = RecentProjectsStore()

    private enum Key {
        static let recent = "recentProjectPaths"
        static let last = "lastRecordedProjectPath"
        static let external = "externalProjectPaths"
    }

    @Published private(set) var recent: [URL]
    @Published private(set) var lastRecorded: URL?
    /// Projects outside the recordings dir that were ever opened. Uncapped;
    /// removed explicitly via `remove(_:)`.
    @Published private(set) var externalProjects: [URL]

    private let defaults: UserDefaults
    private let recordingsDirectory: URL
    private let noteSystemRecent: (URL) -> Void

    init(defaults: UserDefaults = .standard,
         recordingsDirectory: URL = ProjectBundle.defaultRecordingsDirectory(),
         noteSystemRecent: @escaping (URL) -> Void = { NSDocumentController.shared.noteNewRecentDocumentURL($0) }) {
        self.defaults = defaults
        self.recordingsDirectory = recordingsDirectory
        self.noteSystemRecent = noteSystemRecent
        func urls(_ key: String) -> [URL] {
            (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        recent = urls(Key.recent)
        externalProjects = urls(Key.external)
        lastRecorded = defaults.string(forKey: Key.last).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func noteOpened(_ url: URL) {
        recent = RecentProjects.adding(url, to: recent)
        if !isUnderRecordingsDirectory(url) {
            externalProjects = RecentProjects.adding(url, to: externalProjects, limit: .max)
        }
        persist()
        noteSystemRecent(url)
    }

    func noteRecorded(_ url: URL) {
        lastRecorded = url
        noteOpened(url)
    }

    /// Clears the Recent list only; external projects stay in the library.
    func clearRecents() {
        recent = []
        persist()
    }

    /// Swaps a moved/renamed project in place, keeping list positions.
    func replace(_ old: URL, with new: URL) {
        let oldKey = ProjectLibrary.identity(of: old)
        func swap(_ list: [URL]) -> [URL] {
            var seen: Set<String> = []
            return list.map { ProjectLibrary.identity(of: $0) == oldKey ? new : $0 }
                .filter { seen.insert(ProjectLibrary.identity(of: $0)).inserted }
        }
        recent = swap(recent)
        externalProjects = swap(externalProjects)
        if let last = lastRecorded, ProjectLibrary.identity(of: last) == oldKey { lastRecorded = new }
        persist()
    }

    func remove(_ url: URL) {
        let key = ProjectLibrary.identity(of: url)
        recent.removeAll { ProjectLibrary.identity(of: $0) == key }
        externalProjects.removeAll { ProjectLibrary.identity(of: $0) == key }
        if let last = lastRecorded, ProjectLibrary.identity(of: last) == key { lastRecorded = nil }
        persist()
    }

    /// Trailing-slash-safe prefix check ("/a/Capture Studio2" is not under
    /// "/a/Capture Studio").
    private func isUnderRecordingsDirectory(_ url: URL) -> Bool {
        var base = recordingsDirectory.standardizedFileURL.path
        if !base.hasSuffix("/") { base += "/" }
        return url.standardizedFileURL.path.hasPrefix(base)
    }

    private func persist() {
        defaults.set(recent.map { $0.standardizedFileURL.path }, forKey: Key.recent)
        defaults.set(externalProjects.map { $0.standardizedFileURL.path }, forKey: Key.external)
        if let lastRecorded {
            defaults.set(lastRecorded.standardizedFileURL.path, forKey: Key.last)
        } else {
            defaults.removeObject(forKey: Key.last)
        }
    }
}
