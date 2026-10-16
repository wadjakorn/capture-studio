import Foundation

enum ProjectStatus: Equatable {
    case ready
    /// Bundle is being written by the live recording session.
    case recording
    /// No `meta.json` and not the active recording (crash leftover).
    case incomplete
    /// `meta.json` exists but cannot be decoded (e.g. written by a newer version).
    case unreadable
}

struct ProjectSummary: Identifiable, Equatable {
    let url: URL
    var name: String
    var recordedAt: Date?
    var status: ProjectStatus
    var hasCamera: Bool
    var byteSize: Int64
    /// Lives outside the recordings directory (opened from elsewhere).
    var isExternal: Bool

    var id: String { ProjectLibrary.identity(of: url) }
}

enum ProjectSort { case newest, oldest, name, size }

/// Pure scan/sort/filter/group helpers behind the Dashboard. No UI, no
/// singletons — callers pass in recents and the active recording URL.
enum ProjectLibrary {
    enum RenameError: Equatable { case empty, invalidCharacters, duplicate }

    /// Path identity. Symlinks are resolved so `/var` vs `/private/var` spellings
    /// of one folder dedupe and classify consistently.
    static func identity(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func scan(directory: URL, extra: [URL], activeRecording: URL?,
                     fileManager: FileManager = .default) -> [ProjectSummary] {
        let dirID = identity(of: directory)
        let activeID = activeRecording.map(identity(of:))

        var candidates: [URL] = []
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        candidates += entries.filter { $0.pathExtension == ProjectBundle.pathExtension }
        candidates += extra.filter {
            $0.pathExtension == ProjectBundle.pathExtension
                && fileManager.fileExists(atPath: $0.path)
        }

        var seen = Set<String>()
        var result: [ProjectSummary] = []
        for url in candidates {
            let id = identity(of: url)
            guard seen.insert(id).inserted else { continue }
            let parentID = identity(of: url.deletingLastPathComponent())
            result.append(summary(for: url, isActive: id == activeID,
                                  isExternal: parentID != dirID, fileManager: fileManager))
        }
        return result
    }

    private static func summary(for url: URL, isActive: Bool, isExternal: Bool,
                                fileManager: FileManager) -> ProjectSummary {
        let bundle = ProjectBundle(url: url)
        var status = ProjectStatus.ready
        var recordedAt: Date?
        var hasCamera = false
        if isActive {
            status = .recording
        } else if !fileManager.fileExists(atPath: bundle.metaURL.path) {
            status = .incomplete
        } else if let meta = try? bundle.loadMeta() {
            recordedAt = meta.recordedAt
            hasCamera = meta.tracks.contains { $0.type == .camera }
        } else {
            status = .unreadable
        }
        return ProjectSummary(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            recordedAt: recordedAt,
            status: status,
            hasCamera: hasCamera,
            byteSize: byteSize(of: url, fileManager: fileManager),
            isExternal: isExternal)
    }

    private static func byteSize(of url: URL, fileManager: FileManager) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Sort / filter / group

    static func sorted(_ items: [ProjectSummary], by sort: ProjectSort) -> [ProjectSummary] {
        switch sort {
        case .newest:
            return items.sorted { dateOrder($0.recordedAt, $1.recordedAt, newestFirst: true) }
        case .oldest:
            return items.sorted { dateOrder($0.recordedAt, $1.recordedAt, newestFirst: false) }
        case .name:
            return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return items.sorted { $0.byteSize > $1.byteSize }
        }
    }

    /// Undated entries always sort last, regardless of direction.
    private static func dateOrder(_ a: Date?, _ b: Date?, newestFirst: Bool) -> Bool {
        switch (a, b) {
        case let (a?, b?): return newestFirst ? a > b : a < b
        case (_?, nil): return true
        default: return false
        }
    }

    static func filtered(_ items: [ProjectSummary], query: String) -> [ProjectSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func grouped(_ items: [ProjectSummary], now: Date,
                        calendar: Calendar = .current) -> [(title: String, items: [ProjectSummary])] {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var buckets: [[ProjectSummary]] = [[], [], []]
        for item in items {
            guard let date = item.recordedAt else { buckets[2].append(item); continue }
            if calendar.isDate(date, inSameDayAs: now) {
                buckets[0].append(item)
            } else if date >= weekStart && date < today {
                buckets[1].append(item)
            } else {
                buckets[2].append(item)
            }
        }
        let titles = ["Today", "This Week", "Earlier"]
        return zip(titles, buckets).filter { !$0.1.isEmpty }.map { (title: $0.0, items: $0.1) }
    }

    // MARK: - Names

    static func validateRename(_ name: String, existing: Set<String>) -> RenameError? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.contains("/") || trimmed.contains(":") || trimmed.hasPrefix(".") {
            return .invalidCharacters
        }
        let lowered = trimmed.lowercased()
        if existing.contains(where: { $0.lowercased() == lowered }) { return .duplicate }
        return nil
    }

    static func duplicateName(for name: String, existing: Set<String>) -> String {
        var candidate = "\(name) copy"
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(name) copy \(n)"
            n += 1
        }
        return candidate
    }
}
