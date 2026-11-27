import Foundation
import CoreGraphics

/// Tunables for auto-generated zoom blocks.
struct AutoZoomSuggestConfig {
    /// Zoom ramp durations the generated blocks will get (`AutoZoomTrack.rampFor`
    /// of the default sensitivity).
    var rampIn: Double
    var rampOut: Double
    /// How long the zoom lingers after the last action.
    var postHold = 1.2
    /// The shortest un-zoomed gap worth showing; anything shorter is pumping.
    var minWide = 1.0
    /// The zoom lands this long before the first action.
    var preRollPad = 0.2
    /// A scroll burst at least this long means "show the whole page".
    var scrollSplit = 0.5
    /// A typing burst at least this long holds the frame on the text field.
    var typingMin = 1.0
    /// How far back to look for the click that focused the text field.
    var typingClickWindow = 10.0
    /// Shortest time at full zoom between the ramps.
    var minHold = 1.0

    var preRoll: Double { rampIn + preRollPad }
    /// Actions closer than this would leave an un-zoomed gap under `minWide`.
    var joinGap: Double { postHold + preRoll + minWide }
    var minLength: Double { rampIn + rampOut + minHold }
}

/// What "Auto zoom" replaces.
enum AutoZoomScope: Equatable {
    /// Every zoom block, for the whole recording.
    case all
    /// Only this block, using only the activity inside its span.
    case block(UUID)
}

/// Pure generator: recorded activity → ordinary, editable zoom blocks. It only
/// decides WHEN to be zoomed in; all panning inside the blocks is the shot
/// planner's job (`AutoZoomTrack`). No AVFoundation / AppKit deps — unit-tested.
enum AutoZoomSuggester {
    private struct Item {
        var begin: Double
        var end: Double
        /// Set for typing bursts long enough to hold the frame: where to hold it
        /// (normalized 0…1 of the source).
        var hold: CGPoint?
    }

    private struct Run {
        var begin: Double
        var end: Double
        var firstActivity: Double
        var lastActivity: Double
        var holds: [Item]
    }

    /// Generate zoom blocks for `span` (master-timeline seconds). Only activity
    /// inside `span` is used and every block lies inside it.
    ///
    /// Clustering runs on the cut timeline — two clicks either side of a cut are
    /// adjacent for the viewer — and the result is mapped back to master time,
    /// where blocks are stored.
    static func suggest(activity: ZoomActivity, cursorSamples: [CursorSample],
                        span: ClosedRange<Double>, sourceSize: CGSize,
                        cuts: [Range<Double>], config: AutoZoomSuggestConfig) -> [ZoomBlock] {
        guard span.upperBound > span.lowerBound, sourceSize.width > 0, sourceSize.height > 0
        else { return [] }
        let lo = TimelineCut.map(span.lowerBound, cuts: cuts)
        let hi = TimelineCut.map(span.upperBound, cuts: cuts)

        func collapse(_ s: TimeSpan) -> TimeSpan? {
            if s.end <= s.begin {
                return TimelineCut.point(s.begin, cuts: cuts).map { TimeSpan(begin: $0, end: $0) }
            }
            return TimelineCut.span(begin: s.begin, end: s.end, cuts: cuts)
                .map { TimeSpan(begin: $0.begin, end: $0.end) }
        }

        // Scroll bursts long enough to mean "show the whole page".
        let splits = activity.scrolls.compactMap(collapse)
            .filter { $0.length >= config.scrollSplit }.sorted { $0.begin < $1.begin }
        func splitBetween(_ a: Double, _ b: Double) -> Bool {
            splits.contains { $0.begin >= a - 1e-9 && $0.end <= b + 1e-9 }
        }

        // --- Activity items on the collapsed timeline ---------------------------
        var items: [Item] = []
        for c in activity.clicks {
            if let t = TimelineCut.point(c.t, cuts: cuts) { items.append(Item(begin: t, end: t)) }
        }
        for d in activity.drags {
            if let s = collapse(d) { items.append(Item(begin: s.begin, end: s.end)) }
        }
        for typed in activity.typing {
            guard let s = collapse(typed) else { continue }
            var item = Item(begin: s.begin, end: s.end)
            if s.length >= config.typingMin {
                item.hold = typingFocus(typed, activity: activity, cursorSamples: cursorSamples,
                                        sourceSize: sourceSize, window: config.typingClickWindow)
            }
            items.append(item)
        }
        // Anything overlapping the span counts, clipped to it (a drag or typing
        // burst that starts just before a block still belongs to it).
        items = items
            .filter { $0.end >= lo - 1e-9 && $0.begin <= hi + 1e-9 }
            .map { var i = $0; i.begin = max(i.begin, lo); i.end = min(i.end, hi); return i }
            .filter { item in !splits.contains { item.begin <= $0.end && item.end >= $0.begin } }
            .sorted { $0.begin < $1.begin }
        guard !items.isEmpty else { return [] }

        // --- Cluster in time ----------------------------------------------------
        var clusters: [[Item]] = []
        var clusterEnd = 0.0
        for item in items {
            if !clusters.isEmpty, item.begin - clusterEnd <= config.joinGap,
               !splitBetween(clusterEnd, item.begin) {
                clusters[clusters.count - 1].append(item)
                clusterEnd = max(clusterEnd, item.end)
            } else {
                clusters.append([item])
                clusterEnd = item.end
            }
        }

        // --- One run per cluster ------------------------------------------------
        var runs: [Run] = []
        for cluster in clusters {
            let firstT = cluster[0].begin
            let lastT = cluster.map(\.end).max() ?? firstT
            // A splitting scroll is a wall the run may not cross.
            let lower = max(lo, splits.filter { $0.end <= firstT + 1e-9 }.map(\.end).max() ?? lo)
            let upper = min(hi, splits.filter { $0.begin >= lastT - 1e-9 }.map(\.begin).min() ?? hi)
            var begin = max(firstT - config.preRoll, lower)
            var end = min(lastT + config.postHold, upper)
            if end - begin < config.minLength { end = min(begin + config.minLength, upper) }
            if end - begin < config.minLength { begin = max(end - config.minLength, lower) }
            guard end - begin >= config.minLength - 1e-9 else { continue }

            let run = Run(begin: begin, end: end, firstActivity: firstT, lastActivity: lastT,
                          holds: cluster.filter { $0.hold != nil })
            // Too close to the previous run to show a worthwhile un-zoomed gap
            // (e.g. a minimum-length extension closed it): one run. A splitting
            // scroll between them always keeps them apart.
            if let prev = runs.last, run.begin < prev.end + config.minWide - 1e-9,
               !splitBetween(prev.lastActivity, run.firstActivity) {
                runs[runs.count - 1].end = max(prev.end, run.end)
                runs[runs.count - 1].lastActivity = max(prev.lastActivity, run.lastActivity)
                runs[runs.count - 1].holds += run.holds
            } else {
                runs.append(run)
            }
        }

        // --- Blocks: follow, with typing bursts held on the text field ---------
        var blocks: [ZoomBlock] = []
        func emit(_ begin: Double, _ end: Double, hold: CGPoint?) {
            // Back to master time, clamped into the requested span.
            let b = max(TimelineCut.unmap(begin, cuts: cuts), span.lowerBound)
            let e = min(TimelineCut.unmap(end, cuts: cuts), span.upperBound)
            guard e - b > 1e-6 else { return }
            if let hold {
                blocks.append(ZoomBlock(begin: b, end: e, mode: .manual,
                                        focusX: Double(hold.x), focusY: Double(hold.y)))
            } else {
                blocks.append(ZoomBlock(begin: b, end: e))
            }
        }
        for run in runs {
            // (begin, end, hold) pieces that tile the run exactly.
            var pieces: [(Double, Double, CGPoint?)] = []
            var cursor = run.begin
            for item in run.holds.sorted(by: { $0.begin < $1.begin }) {
                var tb = max(item.begin, cursor)
                let te = min(item.end, run.end)
                guard te - tb >= config.typingMin else { continue }
                if tb - cursor >= ZoomTimeline.splitMinWidth {
                    pieces.append((cursor, tb, nil))
                } else {
                    tb = cursor     // sliver before the burst: absorb it
                }
                pieces.append((tb, te, item.hold))
                cursor = te
            }
            if run.end - cursor >= ZoomTimeline.splitMinWidth || pieces.isEmpty {
                pieces.append((cursor, run.end, nil))
            } else {
                pieces[pieces.count - 1].1 = run.end   // sliver after: absorb it
            }
            for p in pieces { emit(p.0, p.1, hold: p.2) }
        }
        return blocks
    }

    /// Where to hold the frame while typing: the click that focused the field if
    /// there was one shortly before, else wherever the pointer was. Normalized.
    private static func typingFocus(_ typed: TimeSpan, activity: ZoomActivity,
                                    cursorSamples: [CursorSample], sourceSize: CGSize,
                                    window: Double) -> CGPoint? {
        let click = activity.clicks.last { $0.t <= typed.begin && $0.t >= typed.begin - window }
        guard let p = click?.p ?? CursorOverlay.position(at: typed.begin, in: cursorSamples)?.p
        else { return nil }
        return CGPoint(x: min(max(p.x / sourceSize.width, 0), 1),
                       y: min(max(p.y / sourceSize.height, 0), 1))
    }

    // MARK: - Applying a result

    /// The time range `scope` covers; nil when `.block` names a block that is no
    /// longer in `existing` (a stale selection must never become "replace all").
    static func span(for scope: AutoZoomScope, existing: [ZoomBlock],
                     duration: Double) -> ClosedRange<Double>? {
        switch scope {
        case .all:
            return duration > 0 ? 0...duration : nil
        case .block(let id):
            guard let b = existing.first(where: { $0.id == id }), b.end > b.begin else { return nil }
            return b.begin...b.end
        }
    }

    /// `.all` → `generated`. `.block(id)` → `existing` with that one block
    /// replaced by `generated`. Sorted by begin.
    static func merge(existing: [ZoomBlock], generated: [ZoomBlock],
                      scope: AutoZoomScope) -> [ZoomBlock] {
        switch scope {
        case .all:
            return generated.sorted { $0.begin < $1.begin }
        case .block(let id):
            return (existing.filter { $0.id != id } + generated).sorted { $0.begin < $1.begin }
        }
    }

    /// The new block list, or nil when nothing should change: nothing was
    /// generated, or the scope names a block that no longer exists.
    static func resolve(existing: [ZoomBlock], generated: [ZoomBlock],
                        scope: AutoZoomScope) -> [ZoomBlock]? {
        guard !generated.isEmpty else { return nil }
        if case .block(let id) = scope, !existing.contains(where: { $0.id == id }) { return nil }
        return merge(existing: existing, generated: generated, scope: scope)
    }
}
