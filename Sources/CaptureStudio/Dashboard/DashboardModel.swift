import AppKit

extension Notification.Name {
    /// Posted (main actor) whenever a bundle appears or disappears from the
    /// recordings dir outside the Dashboard's own file ops: arm, cancel/fail, stop.
    static let projectLibraryDidChange = Notification.Name("CaptureStudio.projectLibraryDidChange")
}

enum DashboardError: LocalizedError {
    case locked
    case notReady
    case rename(ProjectLibrary.RenameError)

    var errorDescription: String? {
        switch self {
        case .locked: return "This project is open in Studio or being recorded."
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
    /// Ids currently being duplicated (the card shows a spinner).
    @Published private(set) var busy: Set<String> = []

    private let directory: URL
    private let recents: RecentProjectsStore
    private let isOpen: (URL) -> Bool
    private let activeRecording: () -> URL?
    private var loadTask: Task<Void, Never>?

    init(directory: URL = ProjectBundle.defaultRecordingsDirectory(),
         recents: RecentProjectsStore? = nil,
         isOpen: ((URL) -> Bool)? = nil,
         activeRecording: (() -> URL?)? = nil) {
        self.directory = directory
        self.recents = recents ?? .shared
        // Defaults resolved here: default-argument closures are nonisolated and
        // can't touch the main-actor singletons.
        self.isOpen = isOpen ?? { StudioLauncher.isOpen($0) }
        self.activeRecording = activeRecording ?? { RecordingSession.shared?.activeBundleURL }
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
        isOpen(project.url) || project.status == .recording
    }

    func open(_ project: ProjectSummary) {
        guard project.status == .ready else { return }
        StudioLauncher.open(bundleURL: project.url)
    }

    func revealInFinder(_ project: ProjectSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }

    func rename(_ project: ProjectSummary, to newName: String) throws {
        guard !isLocked(project) else { throw DashboardError.locked }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = project.url.deletingLastPathComponent()
        // Exclude the project itself so a case-only rename isn't a "duplicate".
        let existing = siblingNames(in: parent, excluding: project.url)
        if let error = ProjectLibrary.validateRename(trimmed, existing: existing) {
            throw DashboardError.rename(error)
        }
        let destination = parent.appendingPathComponent(
            "\(trimmed).\(ProjectBundle.pathExtension)", isDirectory: true)
        try FileManager.default.moveItem(at: project.url, to: destination)
        recents.replace(project.url, with: destination)
        reload()
    }

    func duplicate(_ project: ProjectSummary) async throws {
        guard project.status == .ready else { throw DashboardError.notReady }
        let parent = project.url.deletingLastPathComponent()
        let name = ProjectLibrary.duplicateName(
            for: project.name, existing: siblingNames(in: parent, excluding: nil))
        let source = project.url
        let destination = parent.appendingPathComponent(
            "\(name).\(ProjectBundle.pathExtension)", isDirectory: true)
        busy.insert(project.id)
        defer { busy.remove(project.id) }
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
        await reloadAndWait()
    }

    func moveToTrash(_ project: ProjectSummary) throws {
        guard !isLocked(project) else { throw DashboardError.locked }
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
