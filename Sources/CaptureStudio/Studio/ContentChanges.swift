import Foundation
import CoreGraphics

/// Something on screen changed: the pixels inside the box changed between `t0`
/// and `t1` (master-timeline seconds). The box is normalized (0…1 of the
/// source, top-left origin) so it does not depend on the analysis resolution.
struct ChangeEvent: Codable, Equatable {
    var t0: Double
    var t1: Double
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    /// Changed cells ÷ all cells, over the whole event.
    var coverage: Double
    /// Changed cells ÷ cells in the bounding box, over the whole event.
    var density: Double

    func rect(in sourceSize: CGSize) -> CGRect {
        CGRect(x: x * sourceSize.width, y: y * sourceSize.height,
               width: w * sourceSize.width, height: h * sourceSize.height)
    }
}

/// A coarse grid over a frame; `bits[row * cols + col]` marks a changed cell.
struct CellMask: Equatable {
    var cols: Int
    var rows: Int
    var bits: [Bool]

    init(cols: Int, rows: Int, bits: [Bool]? = nil) {
        self.cols = cols
        self.rows = rows
        self.bits = bits ?? [Bool](repeating: false, count: cols * rows)
    }

    var isEmpty: Bool { !bits.contains(true) }
}

/// Pure frame differencing on 8-bit luma. No AVFoundation deps — unit-tested.
enum LumaDiff {
    /// Mark each `cell`×`cell` block where at least `minPixels` pixels differ by
    /// more than `threshold`. Both frames are `width`×`height`, row-major.
    static func changedCells(previous: [UInt8], current: [UInt8], width: Int, height: Int,
                             cell: Int = 8, threshold: Int = 12,
                             minPixels: Int = 4) -> CellMask {
        guard width > 0, height > 0, cell > 0,
              previous.count >= width * height, current.count >= width * height else {
            return CellMask(cols: 0, rows: 0)
        }
        let cols = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        var counts = [Int](repeating: 0, count: cols * rows)
        previous.withUnsafeBufferPointer { a in
            current.withUnsafeBufferPointer { b in
                for y in 0..<height {
                    let row = (y / cell) * cols, base = y * width
                    for x in 0..<width where abs(Int(a[base + x]) - Int(b[base + x])) > threshold {
                        counts[row + x / cell] += 1
                    }
                }
            }
        }
        return CellMask(cols: cols, rows: rows, bits: counts.map { $0 >= minPixels })
    }
}

/// Groups per-frame changed cells into `ChangeEvent`s: change that is close in
/// time AND touching in space is one event, so a spinner in one corner does not
/// merge with a menu opening in another. Pure — unit-tested.
struct ChangeGrouper {
    /// Change in the same place closer than this (seconds) is one event.
    var joinGap = 0.25
    /// A continuing event is closed after this long so ongoing motion does not
    /// become one ever-growing box.
    var maxLength = 2.0
    /// Times (ascending) at which every open event is closed — mouse-downs, so
    /// what a click causes is never merged with what came before it.
    var splitTimes: [Double] = []

    private struct Open {
        var t0: Double
        var t1: Double
        var frames: Int
        var mask: CellMask
        var minC: Int, maxC: Int, minR: Int, maxR: Int

        func touches(minC c0: Int, maxC c1: Int, minR r0: Int, maxR r1: Int) -> Bool {
            c0 <= maxC + 1 && c1 >= minC - 1 && r0 <= maxR + 1 && r1 >= minR - 1
        }
    }

    private var open: [Open] = []
    private var done: [ChangeEvent] = []
    private var nextSplit = 0

    init(splitTimes: [Double] = []) {
        self.splitTimes = splitTimes.sorted()
    }

    /// Feed the changed cells of the frame shown at `t` (ascending).
    mutating func add(t: Double, mask: CellMask) {
        var split = false
        while nextSplit < splitTimes.count && splitTimes[nextSplit] <= t {
            split = true
            nextSplit += 1
        }
        if split {
            closeAll()
        } else {
            var i = 0
            while i < open.count {
                if t - open[i].t1 > joinGap || t - open[i].t0 > maxLength {
                    close(open.remove(at: i))
                } else {
                    i += 1
                }
            }
        }
        guard !mask.isEmpty else { return }
        // A frame that redraws most of the picture starts its own event, so the
        // redraw is not dated back to whatever was already animating.
        let changed = mask.bits.reduce(0) { $0 + ($1 ? 1 : 0) }
        if Double(changed) >= ContentHints.wideCoverage * Double(mask.bits.count) { closeAll() }

        for comp in Self.components(mask) {
            let hits = open.indices.filter {
                open[$0].mask.cols == mask.cols && open[$0].mask.rows == mask.rows
                    && open[$0].touches(minC: comp.minC, maxC: comp.maxC,
                                        minR: comp.minR, maxR: comp.maxR)
            }
            var target: Open
            if let first = hits.first {
                target = open[first]
                // The component bridges several events: they are one.
                for other in hits.dropFirst() {
                    let o = open[other]
                    target.t0 = min(target.t0, o.t0)
                    target.frames = max(target.frames, o.frames)
                    for k in o.mask.bits.indices where o.mask.bits[k] { target.mask.bits[k] = true }
                    target.minC = min(target.minC, o.minC); target.maxC = max(target.maxC, o.maxC)
                    target.minR = min(target.minR, o.minR); target.maxR = max(target.maxR, o.maxR)
                }
                for other in hits.reversed() { open.remove(at: other) }
                if target.t1 < t { target.frames += 1 }
            } else {
                target = Open(t0: t, t1: t, frames: 1,
                              mask: CellMask(cols: mask.cols, rows: mask.rows),
                              minC: comp.minC, maxC: comp.maxC, minR: comp.minR, maxR: comp.maxR)
            }
            target.t1 = t
            for k in comp.cells { target.mask.bits[k] = true }
            target.minC = min(target.minC, comp.minC); target.maxC = max(target.maxC, comp.maxC)
            target.minR = min(target.minR, comp.minR); target.maxR = max(target.maxR, comp.maxR)
            open.append(target)
        }
    }

    /// Close everything and return all events, ordered by start.
    mutating func finish() -> [ChangeEvent] {
        closeAll()
        let out = done.sorted { ($0.t0, $0.x, $0.y) < ($1.t0, $1.x, $1.y) }
        done = []
        return out
    }

    private mutating func closeAll() {
        for o in open { close(o) }
        open = []
    }

    private mutating func close(_ o: Open) {
        let cols = o.mask.cols, rows = o.mask.rows
        guard cols > 0, rows > 0 else { return }
        let cells = o.mask.bits.reduce(0) { $0 + ($1 ? 1 : 0) }
        let bw = o.maxC - o.minC + 1, bh = o.maxR - o.minR + 1
        // A lone cell for a single frame: caret blink, clock tick.
        if cells <= 1 && o.frames <= 1 { return }
        // A thin strip across most of the picture: progress bar, scrollbar.
        if (bh <= 1 && Double(bw) >= 0.6 * Double(cols))
            || (bw <= 1 && Double(bh) >= 0.6 * Double(rows)) { return }
        done.append(ChangeEvent(
            t0: o.t0, t1: o.t1,
            x: Double(o.minC) / Double(cols), y: Double(o.minR) / Double(rows),
            w: Double(bw) / Double(cols), h: Double(bh) / Double(rows),
            coverage: Double(cells) / Double(cols * rows),
            density: Double(cells) / Double(bw * bh)))
    }

    private struct Component {
        var cells: [Int]
        var minC: Int, maxC: Int, minR: Int, maxR: Int
    }

    /// 8-connected components of the set cells.
    private static func components(_ mask: CellMask) -> [Component] {
        var seen = [Bool](repeating: false, count: mask.bits.count)
        var out: [Component] = []
        for start in mask.bits.indices where mask.bits[start] && !seen[start] {
            var comp = Component(cells: [], minC: .max, maxC: .min, minR: .max, maxR: .min)
            var stack = [start]
            seen[start] = true
            while let k = stack.popLast() {
                let r = k / mask.cols, c = k % mask.cols
                comp.cells.append(k)
                comp.minC = min(comp.minC, c); comp.maxC = max(comp.maxC, c)
                comp.minR = min(comp.minR, r); comp.maxR = max(comp.maxR, r)
                for dr in -1...1 {
                    for dc in -1...1 where dr != 0 || dc != 0 {
                        let nr = r + dr, nc = c + dc
                        guard nr >= 0, nr < mask.rows, nc >= 0, nc < mask.cols else { continue }
                        let n = nr * mask.cols + nc
                        if mask.bits[n] && !seen[n] { seen[n] = true; stack.append(n) }
                    }
                }
            }
            out.append(comp)
        }
        return out
    }
}

/// What a click opened: the content that changed right after it, near it.
/// `t` is the click time; coordinates are source pixels.
struct Reveal: Equatable {
    var t: Double
    var click: CGPoint
    var rect: CGRect
}

/// Readings of the change events that auto zoom acts on. Pure — unit-tested.
enum ContentHints {
    /// An event covering at least this much of the picture is a redraw of the
    /// whole screen (page change, app switch), not something to frame.
    static let wideCoverage = 0.6
    /// A reveal starts at most this long after its click.
    static let revealWindow = 1.0
    /// A reveal's box must be at least this full of changed cells.
    static let revealDensity = 0.3
    /// A reveal lies within this fraction of the source width of its click.
    static let revealReach = 0.25

    /// Start times of whole-screen redraws. During continuous motion (a video
    /// playing) only the first of a chain counts: a later wide event that starts
    /// within `quiet` seconds of the previous one's end is the same motion.
    static func wideMoments(_ changes: [ChangeEvent], quiet: Double = 1.0) -> [Double] {
        var out: [Double] = []
        var lastEnd = -Double.infinity
        for e in changes.sorted(by: { $0.t0 < $1.t0 }) where e.coverage >= wideCoverage {
            if e.t0 - lastEnd > quiet { out.append(e.t0) }
            lastEnd = max(lastEnd, e.t1)
        }
        return out
    }

    /// For each click, the union of the dense, not-whole-screen changes that
    /// start within `revealWindow` after it — and before the next mouse-down in
    /// `mouseDowns`, which owns whatever follows it — and lie near it. Clicks,
    /// mouse-downs and changes must be on the same (master) timeline.
    static func reveals(changes: [ChangeEvent], clicks: [ClickSample],
                        mouseDowns: [Double] = [], sourceSize: CGSize) -> [Reveal] {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return [] }
        let sorted = changes.sorted { $0.t0 < $1.t0 }
        let maxDist = revealReach * Double(sourceSize.width)
        var out: [Reveal] = []
        let downs = (mouseDowns + clicks.map(\.t)).sorted()
        for click in clicks.sorted(by: { $0.t < $1.t }) {
            var union: CGRect?
            let nextDown = downs.first { $0 > click.t + 1e-6 } ?? .infinity
            let until = min(click.t + revealWindow, nextDown - 1e-6)
            for e in sorted {
                if e.t0 > until { break }
                // A frame is stamped when it is shown, so a change caused by the
                // click can only start at or after it.
                guard e.t0 >= click.t - 1e-6, e.coverage < wideCoverage,
                      e.density >= revealDensity else { continue }
                let r = e.rect(in: sourceSize)
                let dx = max(Double(r.minX - click.p.x), 0, Double(click.p.x - r.maxX))
                let dy = max(Double(r.minY - click.p.y), 0, Double(click.p.y - r.maxY))
                guard hypot(dx, dy) <= maxDist else { continue }
                union = union.map { $0.union(r) } ?? r
            }
            if let union { out.append(Reveal(t: click.t, click: click.p, rect: union)) }
        }
        return out
    }
}
