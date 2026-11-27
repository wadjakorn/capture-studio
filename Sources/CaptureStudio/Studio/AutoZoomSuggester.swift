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
    /// How much source (px) the frame shows at 1× — needed to pick a scale from
    /// revealed content. nil = never set a scale.
    var viewSize: CGSize? = nil
    /// Range for a scale chosen from revealed content.
    var minScale = 1.5
    var maxScale = 3.0
    /// Margin kept around revealed content, as a fraction of its size per side.
    var subjectPad = 0.15
    /// Revealed content smaller than this fraction of the view on both axes
    /// does not set a scale.
    var minSubjectFrac = 0.1

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
    ///
    /// Content hints (both in master time, both optional — without them the
    /// result depends on the activity alone):
    /// - `reveals`: what clicks opened. A run containing some gets a scale at
    ///   which each one fits the frame together with its click.
    /// - `wideMoments`: when the whole screen redrew. The zoom is out by then
    ///   and stays out for `minWide`, unless the user is mid-drag or mid-typing.
    static func suggest(activity: ZoomActivity, cursorSamples: [CursorSample],
                        span: ClosedRange<Double>, sourceSize: CGSize,
                        cuts: [Range<Double>], config: AutoZoomSuggestConfig,
                        reveals: [Reveal] = [], wideMoments: [Double] = []) -> [ZoomBlock] {
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
        var splits = activity.scrolls.compactMap(collapse)
            .filter { $0.length >= config.scrollSplit }.sorted { $0.begin < $1.begin }
        // Walls after whole-screen redraws (filled in below). Unlike a scroll
        // burst a wall never discards activity: it only keeps the zoom out, so a
        // click during it gets its block once the wall is over.
        var walls: [TimeSpan] = []
        func splitBetween(_ a: Double, _ b: Double) -> Bool {
            splits.contains { $0.begin >= a - 1e-9 && $0.end <= b + 1e-9 }
                || walls.contains { a <= $0.begin + 1e-9 && b > $0.begin + 1e-9 }
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
        // Whole-screen redraws: the zoom finishes ramping out one ramp after the
        // redraw starts and stays out for `minWide`. A redraw inside a drag or a
        // typing burst is ignored — the user is mid-action there — and a wall
        // ends early when such an action starts during it.
        for moment in wideMoments {
            guard let t = TimelineCut.point(moment, cuts: cuts) else { continue }
            var wall = TimeSpan(begin: t + config.rampOut,
                                end: t + config.rampOut + config.minWide)
            let actions = items.filter { $0.end > $0.begin }
            if actions.contains(where: { $0.begin <= t && $0.end >= t }) { continue }
            if let next = actions.filter({ $0.begin > t }).map(\.begin).min() {
                wall.end = min(wall.end, next)
            }
            if wall.length > 1e-6 { walls.append(wall) }
        }
        walls.sort { $0.begin < $1.begin }

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
            let lower = max(lo, splits.filter { $0.end <= firstT + 1e-9 }.map(\.end).max() ?? lo,
                            walls.filter { $0.begin < firstT - 1e-9 }.map(\.end).max() ?? lo)
            let upper = min(hi, splits.filter { $0.begin >= lastT - 1e-9 }.map(\.begin).min() ?? hi,
                            walls.filter { $0.begin >= lastT - 1e-9 }.map(\.begin).min() ?? hi)
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

        // --- Scale from revealed content ----------------------------------------
        let placed: [(t: Double, fit: Double)] = reveals.compactMap { r in
            guard let view = config.viewSize, view.width > 0, view.height > 0,
                  let t = TimelineCut.point(r.t, cuts: cuts) else { return nil }
            // A control merely reacting to the click (a pressed button) is not
            // content to fit the frame to.
            guard Double(r.rect.width) >= config.minSubjectFrac * Double(view.width)
                    || Double(r.rect.height) >= config.minSubjectFrac * Double(view.height)
            else { return nil }
            // The thing to show: what opened, together with the click that opened it.
            let subject = r.rect.union(CGRect(origin: r.click, size: .zero))
            let grow = 1 + 2 * config.subjectPad
            let fit = min(Double(view.width) / max(Double(subject.width) * grow, 1),
                          Double(view.height) / max(Double(subject.height) * grow, 1))
            return (t, fit)
        }
        /// One scale for the whole run — the largest at which every reveal in it
        /// still fits — so touching blocks never pump. nil without reveals.
        func scale(for run: Run) -> Double? {
            let fits = placed.filter { $0.t >= run.begin - 1e-9 && $0.t <= run.end + 1e-9 }
                .map(\.fit)
            guard let fit = fits.min() else { return nil }
            let clamped = min(max(fit, config.minScale), config.maxScale)
            return (clamped * 20).rounded() / 20
        }

        // --- Blocks: follow, with typing bursts held on the text field ---------
        var blocks: [ZoomBlock] = []
        func emit(_ begin: Double, _ end: Double, hold: CGPoint?, scale: Double?) {
            // Back to master time, clamped into the requested span.
            let b = max(TimelineCut.unmap(begin, cuts: cuts), span.lowerBound)
            let e = min(TimelineCut.unmap(end, cuts: cuts), span.upperBound)
            guard e - b > 1e-6 else { return }
            if let hold {
                blocks.append(ZoomBlock(begin: b, end: e, scale: scale, mode: .manual,
                                        focusX: Double(hold.x), focusY: Double(hold.y)))
            } else {
                blocks.append(ZoomBlock(begin: b, end: e, scale: scale))
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
            let runScale = scale(for: run)
            for p in pieces { emit(p.0, p.1, hold: p.2, scale: runScale) }
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
    /// replaced by `generated`, which inherit its sensitivity and overflow, and
    /// its scale when it had one of its own (the user's choices for that
    /// stretch; a block on the default scale lets a generated scale through).
    /// Sorted by begin.
    static func merge(existing: [ZoomBlock], generated: [ZoomBlock],
                      scope: AutoZoomScope) -> [ZoomBlock] {
        switch scope {
        case .all:
            return generated.sorted { $0.begin < $1.begin }
        case .block(let id):
            let replaced = existing.first { $0.id == id }
            let inherited = generated.map { g -> ZoomBlock in
                var b = g
                b.scale = replaced?.scale ?? g.scale
                b.sensitivity = replaced?.sensitivity
                b.overflow = replaced?.overflow
                return b
            }
            return (existing.filter { $0.id != id } + inherited).sorted { $0.begin < $1.begin }
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
