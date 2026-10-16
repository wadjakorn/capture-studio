import AppKit

extension Notification.Name {
    /// Posted (main actor) whenever a bundle appears or disappears from the
    /// recordings dir outside the Dashboard's own file ops: arm, cancel/fail, stop.
    static let projectLibraryDidChange = Notification.Name("CaptureStudio.projectLibraryDidChange")
}

enum DashboardError: LocalizedError, Equatable {
    case locked
    case busy
    case notReady
    case rename(ProjectLibrary.RenameError)

    var errorDescription: String? {
        switch self {
        case .locked: return "This project is open in Studio or being recorded."
        case .busy: return "This project is being duplicated."
        case .notReady: return "This project isn't ready yet."
        case .rename(.empty): return "Enter a name."
        case .rename(.invalidCharacters): return "Names can't contain “/” or “:” or start with “.”."
        case .rename(.duplicate): return "A project with that name already exists."
        }
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var query = ""
    @Published var sort: ProjectSort = .newest
    @Published private(set) var projects: [ProjectSummary] = []
    /// Ids currently being duplicated (the card shows a spinner). Busy counts
    /// as locked: renaming or trashing the source mid-copy would break it.
    @Published private(set) var busy: Set<String> = []

    private let directory: URL
    private let recents: RecentProjectsStore
    private let isOpen: (URL) -> Bool
    private let activeRecording: () -> URL?
    private let copyItem: @Sendable (URL, URL) throws -> Void
    private var loadTask: Task<Void, Never>?

    init(directory: URL = ProjectBundle.defaultRecordingsDirectory(),
         recents: RecentProjectsStore? = nil,
         isOpen: ((URL) -> Bool)? = nil,
         activeRecording: (() -> URL?)? = nil,
         copyItem: (@Sendable (URL, URL) throws -> Void)? = nil) {
        self.directory = directory
        self.recents = recents ?? .shared
        // Defaults resolved here: default-argument closures are nonisolated and
        // can't touch the main-actor singletons.
        self.isOpen = isOpen ?? { StudioLauncher.isOpen($0) }
        self.activeRecording = activeRecording ?? { RecordingSession.shared?.activeBundleURL }
        // Injectable so tests can fail or stall a copy deterministically.
        self.copyItem = copyItem ?? { try FileManager.default.copyItem(at: $0, to: $1) }
    }

    var visible: [ProjectSummary] {
        ProjectLibrary.sorted(ProjectLibrary.filtered(projects, query: query), by: sort)
    }

    /// Fire-and-forget reload; a newer call cancels the one in flight.
    func reload() { startLoad() }

    /// Awaitable form for tests and callers that need the result.
    func reloadAndWait() async {
        let task = startLoad()
        await task.value
    }

    @discardableResult
    private func startLoad() -> Task<Void, Never> {
        loadTask?.cancel()
        // Snapshot main-actor state here; the scan walks every bundle's files
        // (multi-GB projects) so it must not run on main.
        let directory = directory
        let extra = recents.externalProjects
        let active = activeRecording()
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ProjectLibrary.scan(directory: directory, extra: extra, activeRecording: active)
            }.value
            guard !Task.isCancelled else { return }
            self?.projects = result
        }
        loadTask = task
        return task
    }

    func isLocked(_ project: ProjectSummary) -> Bool {
        if busy.contains(project.id) { return true }
        // Live check too: the snapshot may predate arming.
        if let active = activeRecording(),
           ProjectLibrary.identity(of: active) == project.id { return true }
        return isOpen(project.url) || project.status == .recording
    }

    /// Busy is reported apart so the error names the real reason (the copy),
    /// not "open in Studio".
    private func ensureUnlocked(_ project: ProjectSummary) throws {
        if busy.contains(project.id) { throw DashboardError.busy }
        guard !isLocked(project) else { throw DashboardError.locked }
    }

    func open(_ project: ProjectSummary) {
        guard project.status == .ready else { return }
        StudioLauncher.open(bundleURL: project.url)
    }

    func revealInFinder(_ project: ProjectSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }

    func rename(_ project: ProjectSummary, to newName: String) throws {
        try ensureUnlocked(project)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == project.name { return }
        let parent = project.url.deletingLastPathComponent()
        // Exclude the project itself so a case-only rename isn't a "duplicate".
        let existing = siblingNames(in: parent, excluding: project.url)
        if let error = ProjectLibrary.validateRename(trimmed, existing: existing) {
            throw DashboardError.rename(error)
        }
        let destination = parent.appendingPathComponent(
            "\(trimmed).\(ProjectBundle.pathExtension)", isDirectory: true)
        if Self.isCaseOnlyRename(from: project.url, to: destination) {
            // On case-insensitive APFS the destination "already exists" (it is
            // the source), so a direct move can fail. Hop via a hidden sibling.
            let temp = Self.temporarySibling(for: destination)
            try FileManager.default.moveItem(at: project.url, to: temp)
            do {
                try FileManager.default.moveItem(at: temp, to: destination)
            } catch {
                try? FileManager.default.moveItem(at: temp, to: project.url)
                throw error
            }
        } else {
            try FileManager.default.moveItem(at: project.url, to: destination)
        }
        recents.replace(project.url, with: destination)
        reload()
    }

    func duplicate(_ project: ProjectSummary) async throws {
        guard project.status == .ready else { throw DashboardError.notReady }
        guard !busy.contains(project.id) else { throw DashboardError.busy }
        let parent = project.url.deletingLastPathComponent()
        let name = ProjectLibrary.duplicateName(
            for: project.name, existing: siblingNames(in: parent, excluding: nil))
        let source = project.url
        let destination = parent.appendingPathComponent(
            "\(name).\(ProjectBundle.pathExtension)", isDirectory: true)
        busy.insert(project.id)
        defer { busy.remove(project.id) }
        let copyItem = copyItem
        try await Task.detached(priority: .userInitiated) {
            do {
                try copyItem(source, destination)
            } catch {
                // A copy that died half-way would list as a broken "X copy".
                // Never remove on "file exists": that destination isn't ours.
                if (error as? CocoaError)?.code != .fileWriteFileExists {
                    try? FileManager.default.removeItem(at: destination)
                }
                throw error
            }
        }.value
        // External copies sit beside their source, outside the scanned dir;
        // register them or they'd never show up.
        if project.isExternal { recents.noteOpened(destination) }
        await reloadAndWait()
    }

    func moveToTrash(_ project: ProjectSummary) throws {
        try ensureUnlocked(project)
        try FileManager.default.trashItem(at: project.url, resultingItemURL: nil)
        recents.remove(project.url)
        reload()
    }

    /// Forgets an external project; the files stay where they are.
    func removeFromLibrary(_ project: ProjectSummary) {
        guard project.isExternal else { return }
        recents.remove(project.url)
        reload()
    }

    /// Same folder, names differing only by letter case ("demo" → "Demo").
    nonisolated static func isCaseOnlyRename(from source: URL, to destination: URL) -> Bool {
        let a = source.standardizedFileURL, b = destination.standardizedFileURL
        return a.deletingLastPathComponent().path == b.deletingLastPathComponent().path
            && a.lastPathComponent != b.lastPathComponent
            && a.lastPathComponent.caseInsensitiveCompare(b.lastPathComponent) == .orderedSame
    }

    /// Hidden, unique sibling (`.<name>-<uuid>.capturestudio`) used as the
    /// intermediate hop of a case-only rename.
    nonisolated static func temporarySibling(for destination: URL) -> URL {
        let name = destination.deletingPathExtension().lastPathComponent
        return destination.deletingLastPathComponent().appendingPathComponent(
            ".\(name)-\(UUID().uuidString).\(ProjectBundle.pathExtension)", isDirectory: true)
    }

    private func siblingNames(in parent: URL, excluding: URL?) -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil)) ?? []
        let skip = excluding.map { $0.standardizedFileURL.path }
        return Set(items
            .filter { $0.pathExtension == ProjectBundle.pathExtension
                && $0.standardizedFileURL.path != skip }
            .map { $0.deletingPathExtension().lastPathComponent })
    }
}
