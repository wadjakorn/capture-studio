import Foundation

/// Pure list logic for the tray's "Recent projects". Kept free of AppKit and
/// UserDefaults so it can be unit-tested; `RecentProjectsStore` owns state.
enum RecentProjects {
    static let limit = 10

    /// MRU insert: newest first, deduped by standardized path, capped at `limit`.
    static func adding(_ url: URL, to list: [URL], limit: Int = RecentProjects.limit) -> [URL] {
        let key = url.standardizedFileURL.path
        let rest = list.filter { $0.standardizedFileURL.path != key }
        return Array(([url] + rest).prefix(limit))
    }

    /// Display-time filter. Unopenable entries (deleted, ejected disk, still
    /// recording) are hidden rather than purged, so they reappear if the
    /// bundle comes back. `excluding` is the "Last recording" row's URL.
    static func displayable(_ urls: [URL], excluding: URL?, limit: Int,
                            isOpenable: (URL) -> Bool) -> [URL] {
        var seen: Set<String> = []
        if let excluding { seen.insert(excluding.standardizedFileURL.path) }
        var out: [URL] = []
        for url in urls {
            if out.count >= limit { break }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), isOpenable(url) else { continue }
            seen.insert(key)
            out.append(url)
        }
        return out
    }

    /// A `.capturestudio` bundle whose meta.json exists (written last, so an
    /// in-progress or aborted recording is not openable).
    static func isOpenable(_ url: URL) -> Bool {
        url.pathExtension == ProjectBundle.pathExtension && ProjectBundle(url: url).isFinalized
    }
}
