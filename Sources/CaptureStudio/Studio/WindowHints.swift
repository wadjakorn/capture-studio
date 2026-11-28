import Foundation
import CoreGraphics

/// The window the pointer was over from `begin` until `end`, in source pixels
/// (top-left origin), clipped to the source.
struct WindowSpan: Equatable {
    var begin: Double
    var end: Double
    var rect: CGRect
    /// The window's number at record time: tells "the same window, moved" from
    /// "another window". 0 = unknown.
    var id: Int = 0
}

/// Readings of `windows.jsonl` that the follow camera acts on. Pure —
/// unit-tested.
enum WindowHints {
    /// A window with less than this much of its own area inside the recorded
    /// picture is mostly somewhere else.
    static let minInside = 0.25
    /// A window covering at least this much of the picture bounds nothing.
    static let maxCoverage = 0.85
    /// Edges that move less than this fraction of the source width are jitter.
    static let jitter = 0.01
    /// A window under the pointer for less than this is passing through, or is
    /// being moved or resized (see `spans`).
    static let minStable = 1.0
    /// A first line this soon after the start applies from the start.
    static let leadIn = 0.5

    /// Stable window spans on the master timeline (`0…duration`), ascending,
    /// not overlapping. Stretches without a usable window are simply absent.
    static func spans(lines: [WindowLine], display: DisplayInfo, sourceSize: CGSize,
                      duration: Double) -> [WindowSpan] {
        guard sourceSize.width > 0, sourceSize.height > 0, duration > 0 else { return [] }
        let source = CGRect(origin: .zero, size: sourceSize)
        let tol = jitter * Double(sourceSize.width)
        let sorted = lines.sorted { $0.t < $1.t }

        // What each line says, until the next one.
        struct Piece { var begin: Double; var end: Double; var id: Int; var rect: CGRect? }
        var pieces: [Piece] = []
        for (i, line) in sorted.enumerated() {
            var begin = line.t
            if i == 0 && begin <= leadIn { begin = 0 }
            let end = i + 1 < sorted.count ? sorted[i + 1].t : duration
            begin = min(max(begin, 0), duration)
            let clippedEnd = min(max(end, 0), duration)
            guard clippedEnd > begin else { continue }
            let rect = usable(line, display: display, sourceSize: sourceSize, source: source)
            // The same window, hardly moved: still the same span.
            if let last = pieces.last, last.id == line.id, abs(last.end - begin) < 1e-9,
               let a = last.rect, let b = rect,
               abs(Double(a.minX - b.minX)) <= tol, abs(Double(a.maxX - b.maxX)) <= tol,
               abs(Double(a.minY - b.minY)) <= tol, abs(Double(a.maxY - b.maxY)) <= tol {
                pieces[pieces.count - 1].end = clippedEnd
                continue
            }
            pieces.append(Piece(begin: begin, end: clippedEnd, id: line.id, rect: rect))
        }
        // A window that stays put is a span of its own. While the same window
        // is being moved or resized its frames come too fast to hold a frame
        // on any one of them: that stretch is one span covering everywhere the
        // window was, so the camera can show the whole motion. A window the
        // pointer only passes over (short, and not the same window before or
        // after) is nothing.
        func touches(_ a: Piece, _ b: Piece) -> Bool {
            a.id == b.id && a.rect != nil && b.rect != nil && abs(a.end - b.begin) < 1e-9
        }
        var out: [WindowSpan] = []
        var i = 0
        while i < pieces.count {
            let p = pieces[i]
            guard var rect = p.rect else { i += 1; continue }
            if p.end - p.begin >= minStable {
                out.append(WindowSpan(begin: p.begin, end: p.end, rect: rect, id: p.id))
                i += 1
                continue
            }
            var j = i
            while j + 1 < pieces.count, touches(pieces[j], pieces[j + 1]),
                  pieces[j + 1].end - pieces[j + 1].begin < minStable, let r = pieces[j + 1].rect {
                rect = rect.union(r)
                j += 1
            }
            let sameBefore = i > 0 && touches(pieces[i - 1], p)
            let sameAfter = j + 1 < pieces.count && touches(pieces[j], pieces[j + 1])
            if pieces[j].end - p.begin >= minStable || sameBefore || sameAfter {
                out.append(WindowSpan(begin: p.begin, end: pieces[j].end, rect: rect, id: p.id))
            }
            i = j + 1
        }
        return out
    }

    /// The line's window in source pixels, or nil when it bounds nothing.
    private static func usable(_ line: WindowLine, display: DisplayInfo, sourceSize: CGSize,
                               source: CGRect) -> CGRect? {
        guard !line.isNone else { return nil }
        let a = CursorOverlay.sourcePoint(x: line.x, y: line.y, display: display,
                                          sourceSize: sourceSize)
        let b = CursorOverlay.sourcePoint(x: line.x + line.w, y: line.y + line.h,
                                          display: display, sourceSize: sourceSize)
        let full = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).standardized
        let clipped = full.intersection(source)
        guard !clipped.isNull, full.width > 0, full.height > 0 else { return nil }
        let area = Double(clipped.width * clipped.height)
        guard area >= minInside * Double(full.width * full.height),
              area < maxCoverage * Double(source.width * source.height) else { return nil }
        return clipped
    }

    /// Spans mapped onto the cut timeline: one straddling a cut continues
    /// across it, one wholly inside a cut is dropped.
    static func collapsed(_ spans: [WindowSpan], cuts: [Range<Double>]) -> [WindowSpan] {
        guard !cuts.isEmpty else { return spans }
        return spans.compactMap { s in
            TimelineCut.span(begin: s.begin, end: s.end, cuts: cuts)
                .map { WindowSpan(begin: $0.begin, end: $0.end, rect: s.rect, id: s.id) }
        }
    }

    /// The window at `t` (`begin ≤ t < end`), if any. `spans` ascending.
    static func window(at t: Double, in spans: [WindowSpan]) -> CGRect? {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].end <= t { lo = mid + 1 } else { hi = mid }
        }
        guard lo < spans.count, spans[lo].begin <= t else { return nil }
        return spans[lo].rect
    }
}
