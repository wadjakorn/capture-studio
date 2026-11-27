import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

@Suite struct LumaDiffTests {
    private let w = 32, h = 16

    private func frame(_ fill: UInt8 = 100) -> [UInt8] {
        [UInt8](repeating: fill, count: w * h)
    }

    private func paint(_ f: inout [UInt8], x: Range<Int>, y: Range<Int>, _ v: UInt8) {
        for yy in y { for xx in x { f[yy * w + xx] = v } }
    }

    @Test func identicalFramesHaveNoChange() {
        let m = LumaDiff.changedCells(previous: frame(), current: frame(), width: w, height: h)
        #expect(m.cols == 4 && m.rows == 2)
        #expect(m.isEmpty)
    }

    @Test func changedBlockMarksExactlyItsCells() {
        var b = frame()
        paint(&b, x: 8..<16, y: 0..<8, 200)        // cell (col 1, row 0)
        let m = LumaDiff.changedCells(previous: frame(), current: b, width: w, height: h)
        #expect(m.bits == [false, true, false, false, false, false, false, false])
    }

    @Test func noiseBelowThresholdIsIgnored() {
        let m = LumaDiff.changedCells(previous: frame(100), current: frame(108),
                                      width: w, height: h)
        #expect(m.isEmpty)
    }

    @Test func aFewStrayPixelsAreIgnored() {
        var b = frame()
        paint(&b, x: 0..<3, y: 0..<1, 255)         // 3 pixels < minPixels (4)
        #expect(LumaDiff.changedCells(previous: frame(), current: b, width: w, height: h).isEmpty)
        paint(&b, x: 0..<4, y: 0..<1, 255)
        #expect(!LumaDiff.changedCells(previous: frame(), current: b, width: w, height: h).isEmpty)
    }

    @Test func mismatchedInputIsEmpty() {
        let m = LumaDiff.changedCells(previous: [], current: frame(), width: w, height: h)
        #expect(m.cols == 0 && m.isEmpty)
    }
}

@Suite struct ChangeGrouperTests {
    // 10 × 10 grid.
    private func mask(_ cells: [(c: Int, r: Int)]) -> CellMask {
        var m = CellMask(cols: 10, rows: 10)
        for cell in cells { m.bits[cell.r * 10 + cell.c] = true }
        return m
    }

    private func block(c: Range<Int>, r: Range<Int>) -> CellMask {
        mask(r.flatMap { row in c.map { (c: $0, r: row) } })
    }

    @Test func nothingChangedNoEvents() {
        var g = ChangeGrouper()
        g.add(t: 1, mask: CellMask(cols: 10, rows: 10))
        #expect(g.finish().isEmpty)
    }

    @Test func oneEventWithBoxCoverageAndDensity() {
        var g = ChangeGrouper()
        g.add(t: 1.0, mask: block(c: 2..<4, r: 3..<5))
        g.add(t: 1.1, mask: block(c: 2..<6, r: 3..<5))
        let e = g.finish()
        #expect(e.count == 1)
        guard let ev = e.first else { return }
        #expect(ev.t0 == 1.0 && ev.t1 == 1.1)
        #expect(abs(ev.x - 0.2) < 1e-9 && abs(ev.y - 0.3) < 1e-9)
        #expect(abs(ev.w - 0.4) < 1e-9 && abs(ev.h - 0.2) < 1e-9)
        #expect(abs(ev.coverage - 0.08) < 1e-9)
        #expect(abs(ev.density - 1) < 1e-9)
        let r = ev.rect(in: CGSize(width: 1000, height: 500))
        #expect(r == CGRect(x: 200, y: 150, width: 400, height: 100))
    }

    @Test func changeFarApartInTimeIsTwoEvents() {
        var g = ChangeGrouper()
        g.add(t: 1.0, mask: block(c: 2..<4, r: 3..<5))
        g.add(t: 1.5, mask: block(c: 2..<4, r: 3..<5))     // > joinGap later
        #expect(g.finish().count == 2)
    }

    @Test func simultaneousChangeInSeparatePlacesStaysSeparate() {
        var g = ChangeGrouper()
        var m = block(c: 0..<2, r: 0..<2)
        for k in block(c: 7..<9, r: 7..<9).bits.indices
        where block(c: 7..<9, r: 7..<9).bits[k] { m.bits[k] = true }
        g.add(t: 1.0, mask: m)
        g.add(t: 1.1, mask: m)
        let e = g.finish()
        #expect(e.count == 2)
        #expect(e.allSatisfy { abs($0.w - 0.2) < 1e-9 && abs($0.h - 0.2) < 1e-9 })
    }

    @Test func aBridgingChangeMergesEvents() {
        var g = ChangeGrouper()
        g.add(t: 1.0, mask: block(c: 0..<2, r: 0..<2))
        g.add(t: 1.0, mask: block(c: 5..<7, r: 0..<2))
        g.add(t: 1.1, mask: block(c: 1..<6, r: 0..<2))     // touches both
        let e = g.finish()
        #expect(e.count == 1)
        #expect(abs((e.first?.w ?? 0) - 0.7) < 1e-9)
    }

    @Test func longMotionIsCutIntoPieces() {
        var g = ChangeGrouper()
        var t = 0.0
        while t <= 5.0 {
            g.add(t: t, mask: block(c: 2..<5, r: 2..<5))
            t += 0.1
        }
        let e = g.finish()
        #expect(e.count >= 2)
        #expect(e.allSatisfy { $0.t1 - $0.t0 <= 2.0 + 0.11 })
    }

    @Test func splitTimeSeparatesBeforeFromAfter() {
        // A hover highlight just before the click, the menu right after it.
        var g = ChangeGrouper(splitTimes: [2.0])
        g.add(t: 1.95, mask: block(c: 4..<5, r: 4..<6))
        g.add(t: 2.02, mask: block(c: 4..<7, r: 4..<9))
        let e = g.finish()
        #expect(e.count == 2)
        #expect(e.last?.t0 == 2.02)
    }

    @Test func aWholeScreenRedrawIsDatedFromItsOwnFrame() {
        // Something small is already animating when the page redraws.
        var g = ChangeGrouper()
        g.add(t: 1.0, mask: block(c: 4..<6, r: 4..<6))
        g.add(t: 1.2, mask: block(c: 4..<6, r: 4..<6))
        g.add(t: 1.4, mask: block(c: 0..<10, r: 0..<8))
        let wide = g.finish().filter { $0.coverage >= ContentHints.wideCoverage }
        #expect(wide.count == 1)
        #expect(wide.first?.t0 == 1.4)
    }

    @Test func loneCellForOneFrameIsDropped() {
        var g = ChangeGrouper()
        g.add(t: 1, mask: mask([(c: 3, r: 3)]))
        #expect(g.finish().isEmpty)
        // …but a cell that keeps changing is kept.
        var g2 = ChangeGrouper()
        g2.add(t: 1, mask: mask([(c: 3, r: 3)]))
        g2.add(t: 1.1, mask: mask([(c: 3, r: 3)]))
        #expect(g2.finish().count == 1)
    }

    @Test func thinStripsAreDropped() {
        var g = ChangeGrouper()
        g.add(t: 1, mask: block(c: 0..<8, r: 9..<10))      // progress bar
        g.add(t: 2, mask: block(c: 9..<10, r: 1..<9))      // scrollbar
        #expect(g.finish().isEmpty)
    }
}

@Suite struct ContentHintsTests {
    private let size = CGSize(width: 1000, height: 1000)

    private func event(_ t0: Double, _ t1: Double, x: Double, y: Double, w: Double, h: Double,
                       coverage: Double? = nil, density: Double = 1) -> ChangeEvent {
        ChangeEvent(t0: t0, t1: t1, x: x, y: y, w: w, h: h,
                    coverage: coverage ?? w * h * density, density: density)
    }

    @Test func wideMomentsNeedCoverage() {
        let e = [event(1, 1.2, x: 0, y: 0, w: 1, h: 1),
                 event(5, 5.1, x: 0.1, y: 0.1, w: 0.3, h: 0.3)]
        #expect(ContentHints.wideMoments(e) == [1])
    }

    @Test func continuousWideMotionCountsOnce() {
        // A video playing: back-to-back wide events.
        let e = [event(1, 3, x: 0, y: 0, w: 1, h: 1), event(3.05, 5, x: 0, y: 0, w: 1, h: 1),
                 event(5.05, 7, x: 0, y: 0, w: 1, h: 1), event(20, 20.2, x: 0, y: 0, w: 1, h: 1)]
        #expect(ContentHints.wideMoments(e) == [1, 20])
    }

    @Test func revealIsWhatOpenedNextToTheClick() {
        let click = ClickSample(t: 2, p: CGPoint(x: 500, y: 100))
        let menu = event(2.05, 2.2, x: 0.45, y: 0.12, w: 0.2, h: 0.3)
        let r = ContentHints.reveals(changes: [menu], clicks: [click], sourceSize: size)
        #expect(r == [Reveal(t: 2, click: click.p,
                             rect: CGRect(x: 450, y: 120, width: 200, height: 300))])
    }

    @Test func revealRejections() {
        let click = ClickSample(t: 2, p: CGPoint(x: 500, y: 100))
        func none(_ e: ChangeEvent) -> Bool {
            ContentHints.reveals(changes: [e], clicks: [click], sourceSize: size).isEmpty
        }
        #expect(none(event(1.9, 2.1, x: 0.45, y: 0.12, w: 0.2, h: 0.3)))       // began before
        #expect(none(event(3.2, 3.4, x: 0.45, y: 0.12, w: 0.2, h: 0.3)))       // too late
        #expect(none(event(2.1, 2.2, x: 0.0, y: 0.7, w: 0.1, h: 0.2)))         // too far
        #expect(none(event(2.1, 2.2, x: 0.4, y: 0.1, w: 0.4, h: 0.4, density: 0.1)))  // sparse
        #expect(none(event(2.1, 2.2, x: 0, y: 0, w: 1, h: 1)))                 // whole screen
    }

    @Test func revealStopsAtTheNextMouseDown() {
        let c1 = ClickSample(t: 2.0, p: CGPoint(x: 500, y: 500))
        let c2 = ClickSample(t: 2.6, p: CGPoint(x: 520, y: 520))
        let menu = event(2.05, 2.1, x: 0.5, y: 0.5, w: 0.1, h: 0.1)
        let panel = event(2.65, 2.9, x: 0.3, y: 0.3, w: 0.45, h: 0.6)
        let r = ContentHints.reveals(changes: [menu, panel], clicks: [c1, c2], sourceSize: size)
        #expect(r.count == 2)
        #expect(r.first?.rect == CGRect(x: 500, y: 500, width: 100, height: 100))
        #expect(r.last?.rect == CGRect(x: 300, y: 300, width: 450, height: 600))
        // A drag's mouse-down (not a click) also ends the window.
        let alone = ContentHints.reveals(changes: [menu, panel], clicks: [c1],
                                         mouseDowns: [2.6], sourceSize: size)
        #expect(alone.first?.rect == CGRect(x: 500, y: 500, width: 100, height: 100))
    }

    @Test func revealUnitesWhatFollowsOneClick() {
        let click = ClickSample(t: 2, p: CGPoint(x: 500, y: 500))
        let a = event(2.05, 2.1, x: 0.5, y: 0.5, w: 0.1, h: 0.1)
        let b = event(2.4, 2.6, x: 0.6, y: 0.55, w: 0.1, h: 0.2)
        let r = ContentHints.reveals(changes: [a, b], clicks: [click], sourceSize: size)
        #expect(r.count == 1)
        #expect(r.first?.rect == CGRect(x: 500, y: 500, width: 200, height: 250))
    }
}

@Suite struct ChangeAnalysisCacheTests {
    @Test func roundTripAndRejection() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-changes-\(UUID().uuidString).capturestudio")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = ProjectBundle(url: dir)
        let video = bundle.screenURL
        try Data(count: 1234).write(to: video)
        let analysis = ChangeAnalysis(videoBytes: 1234, events: [
            ChangeEvent(t0: 1, t1: 2, x: 0.1, y: 0.2, w: 0.3, h: 0.4, coverage: 0.1, density: 0.8),
        ])

        // Not a finalized bundle (no meta.json): nothing is written.
        bundle.writeChanges(analysis)
        #expect(bundle.loadChanges(for: video) == nil)
        #expect(!FileManager.default.fileExists(atPath: bundle.changesURL.path))

        try Data("{}".utf8).write(to: bundle.metaURL)
        bundle.writeChanges(analysis)
        #expect(bundle.loadChanges(for: video) == analysis)

        // A different video file: the cache is ignored.
        try Data(count: 999).write(to: video)
        #expect(bundle.loadChanges(for: video) == nil)

        // A newer format version is ignored.
        try Data(count: 1234).write(to: video)
        var future = analysis
        future.version = ChangeAnalysis.currentVersion + 1
        bundle.writeChanges(future)
        #expect(bundle.loadChanges(for: video) == nil)

        // Garbage is ignored.
        try Data("nope".utf8).write(to: bundle.changesURL)
        #expect(bundle.loadChanges(for: video) == nil)
    }

    @Test func aDeletedBundleIsNotRecreated() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-gone-\(UUID().uuidString).capturestudio")
        ProjectBundle(url: dir).writeChanges(ChangeAnalysis(videoBytes: 1, events: []))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
