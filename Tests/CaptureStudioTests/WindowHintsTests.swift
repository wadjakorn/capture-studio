import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

/// Window frames: the file, what the recorder keeps, the spans the editor
/// reads, and how they bound the follow camera and set a scale.
@Suite struct WindowHintsTests {
    private let hd = CGSize(width: 1920, height: 1080)
    // 1920×1080 viewed at 2×: view 960×540, bound margin 67.2 × 37.8.
    private let half = CGSize(width: 480, height: 270)
    private let reach = CGRect(x: 480, y: 270, width: 960, height: 540)
    private let step = 1.0 / 60.0
    private var tuning: FollowTuning { ZoomShotPlanner.followTuning(0.5) }   // safe ±336 × ±189
    private let display = DisplayInfo(displayID: 1, pixelWidth: 1920, pixelHeight: 1080,
                                      pointWidth: 1920, pointHeight: 1080, scaleFactor: 1,
                                      originX: 0, originY: 0)

    // MARK: - File

    @Test func linesRoundTripAndBadLinesAreSkipped() throws {
        let lines = [WindowLine(t: 0.1, id: 7, x: 10, y: 20, w: 300, h: 200), .none(t: 2)]
        var data = try WindowsCodec.encodeLines(lines)
        data.append(Data("not json\n".utf8))
        #expect(WindowsCodec.decodeLines(data) == lines)
        #expect(WindowsCodec.decodeLines(Data()).isEmpty)
        #expect(lines[1].isNone && !lines[0].isNone)
    }

    // MARK: - Recorder

    private func cand(_ id: Int, _ frame: CGRect, pid: Int32 = 10, layer: Int = 0,
                      alpha: Double = 1) -> WindowCandidate {
        WindowCandidate(id: id, pid: pid, layer: layer, alpha: alpha, frame: frame)
    }
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test func picksTheTopmostOrdinaryWindowUnderThePointer() {
        let list = [
            cand(1, CGRect(x: 0, y: 0, width: 1920, height: 30), layer: 24),      // menu bar
            cand(2, CGRect(x: 400, y: 300, width: 300, height: 200), alpha: 0),   // invisible
            cand(3, CGRect(x: 480, y: 380, width: 20, height: 20)),               // tiny
            cand(4, CGRect(x: 100, y: 100, width: 200, height: 200)),             // elsewhere
            cand(5, CGRect(x: 400, y: 300, width: 300, height: 200)),
            cand(6, CGRect(x: 0, y: 0, width: 1920, height: 1080)),               // behind
        ]
        let p = CGPoint(x: 490, y: 390)
        #expect(ActiveWindow.pick(list, pointer: p, captured: screen, ownPID: 99,
                                  contentIDs: [])?.id == 5)
        #expect(ActiveWindow.pick(list, pointer: CGPoint(x: 5, y: 500), captured: screen,
                                  ownPID: 99, contentIDs: [])?.id == 6)
        #expect(ActiveWindow.pick([], pointer: p, captured: screen, ownPID: 99,
                                  contentIDs: []) == nil)
    }

    @Test func ownChromeIsSkippedButAContentWindowCounts() {
        let list = [cand(8, CGRect(x: 400, y: 300, width: 300, height: 200), pid: 99),
                    cand(9, CGRect(x: 300, y: 200, width: 600, height: 500))]
        let p = CGPoint(x: 500, y: 400)
        #expect(ActiveWindow.pick(list, pointer: p, captured: screen, ownPID: 99,
                                  contentIDs: [])?.id == 9)
        #expect(ActiveWindow.pick(list, pointer: p, captured: screen, ownPID: 99,
                                  contentIDs: [8])?.id == 8)
    }

    @Test func aWindowOutsideTheCapturedAreaIsNoWindow() {
        let list = [cand(5, CGRect(x: 2000, y: 100, width: 600, height: 400)),
                    cand(6, CGRect(x: 0, y: 0, width: 4000, height: 1080))]
        #expect(ActiveWindow.pick(list, pointer: CGPoint(x: 2100, y: 200), captured: screen,
                                  ownPID: 99, contentIDs: []) == nil)
    }

    @Test func theLogKeepsOnlyChanges() {
        var log = WindowLog()
        let a = cand(5, CGRect(x: 400, y: 300, width: 300, height: 200))
        log.note(hostTime: 100, window: a)
        log.note(hostTime: 100.1, window: a)
        var moved = a
        moved.frame.origin.x += 0.4
        log.note(hostTime: 100.2, window: moved)       // under a point: unchanged
        moved.frame.origin.x += 40
        log.note(hostTime: 100.3, window: moved)
        log.note(hostTime: 100.4, window: nil)
        log.note(hostTime: 100.5, window: nil)
        log.note(hostTime: 100.6, window: a)
        let lines = log.lines(anchorHostTime: 100)
        #expect(lines.map(\.t) == [0, 0.3, 0.4, 0.6])
        #expect(lines.map(\.isNone) == [false, false, true, false])
        #expect(lines[1].x == 440.4)
    }

    // MARK: - Spans

    private func line(_ t: Double, _ id: Int, _ r: CGRect) -> WindowLine {
        WindowLine(t: t, id: id, x: r.minX, y: r.minY, w: r.width, h: r.height)
    }
    private let win = CGRect(x: 600, y: 300, width: 800, height: 500)

    @Test func aLineHoldsUntilTheNextAndEarlyLinesStartAtZero() {
        let spans = WindowHints.spans(lines: [line(0.1, 5, win), .none(t: 4), line(6, 5, win)],
                                      display: display, sourceSize: hd, duration: 10)
        #expect(spans == [WindowSpan(begin: 0, end: 4, rect: win, id: 5),
                          WindowSpan(begin: 6, end: 10, rect: win, id: 5)])
    }

    @Test func framesMapThroughTheCapturedAreaAndRetinaScale() {
        // An 800×450 pt area at (100, 50), recorded at 2×.
        let area = DisplayInfo(displayID: 1, pixelWidth: 1600, pixelHeight: 900,
                               pointWidth: 800, pointHeight: 450, scaleFactor: 2,
                               originX: 100, originY: 50)
        let spans = WindowHints.spans(
            lines: [line(0, 5, CGRect(x: 200, y: 100, width: 300, height: 200))],
            display: area, sourceSize: CGSize(width: 1600, height: 900), duration: 5)
        #expect(spans.map(\.rect) == [CGRect(x: 200, y: 100, width: 600, height: 400)])
    }

    @Test func windowsThatBoundNothingAreLeftOut() {
        func rects(_ r: CGRect) -> [CGRect] {
            WindowHints.spans(lines: [line(0, 5, r)], display: display, sourceSize: hd,
                              duration: 5).map(\.rect)
        }
        // Nearly the whole picture.
        #expect(rects(CGRect(x: 0, y: 30, width: 1920, height: 1050)).isEmpty)
        // Mostly outside the picture.
        #expect(rects(CGRect(x: 1800, y: 300, width: 800, height: 500)).isEmpty)
        // Partly outside: clipped.
        #expect(rects(CGRect(x: 1500, y: 300, width: 800, height: 500))
                == [CGRect(x: 1500, y: 300, width: 420, height: 500)])
    }

    @Test func jitterIsOneSpanAndAMovingWindowIsNone() {
        var nudged = win
        nudged.origin.x += 10
        let steady = WindowHints.spans(lines: [line(0, 5, win), line(2, 5, nudged)],
                                       display: display, sourceSize: hd, duration: 6)
        #expect(steady == [WindowSpan(begin: 0, end: 6, rect: win, id: 5)])

        // Dragged across the screen: a new frame every 0.25 s, then it rests.
        var lines = [line(0, 5, win)]
        for i in 1...8 {
            var r = win
            r.origin.x -= CGFloat(i) * 60
            lines.append(line(2 + Double(i) * 0.25, 5, r))
        }
        let dragged = WindowHints.spans(lines: lines, display: display, sourceSize: hd,
                                        duration: 10)
        // Before, during (one span covering everywhere it was), after.
        #expect(dragged.map { [$0.begin, $0.end] } == [[0, 2.25], [2.25, 4], [4, 10]])
        #expect(dragged[1].rect == CGRect(x: 180, y: 300, width: 1160, height: 500))
        #expect(dragged[2].rect.minX == 120)
        #expect(dragged.allSatisfy { $0.id == 5 })

        // Another window the pointer only passes over is nothing.
        let passing = WindowHints.spans(
            lines: [line(0, 5, win), line(3, 9, CGRect(x: 100, y: 100, width: 300, height: 300)),
                    line(3.4, 5, win)],
            display: display, sourceSize: hd, duration: 8)
        #expect(passing.map(\.id) == [5, 5])
    }

    @Test func spansCollapseAcrossCutsAndLookUpByTime() {
        let spans = [WindowSpan(begin: 0, end: 4, rect: win),
                     WindowSpan(begin: 5, end: 6, rect: win),
                     WindowSpan(begin: 8, end: 12, rect: win)]
        let cut = WindowHints.collapsed(spans, cuts: [3..<7])
        #expect(cut.map { [$0.begin, $0.end] } == [[0, 3], [4, 8]])
        #expect(WindowHints.collapsed(spans, cuts: []) == spans)

        #expect(WindowHints.window(at: 0, in: spans) == win)
        #expect(WindowHints.window(at: 3.99, in: spans) == win)
        #expect(WindowHints.window(at: 4, in: spans) == nil)
        #expect(WindowHints.window(at: 7, in: spans) == nil)
        #expect(WindowHints.window(at: 12, in: spans) == nil)
        #expect(WindowHints.window(at: 1, in: []) == nil)
    }

    // MARK: - Bounded reach

    @Test func theViewStaysInsideTheWindowPlusItsMargin() {
        // Wider than the view: the centre may pan, but only this far.
        let r = ZoomShotPlanner.boundedReach(reach, to: CGRect(x: 200, y: 100, width: 1200, height: 880),
                                             half: half)
        #expect(abs(r.minX - (200 - 67.2 + 480)) < 1e-6)
        #expect(abs(r.maxX - (1400 + 67.2 - 480)) < 1e-6)
        #expect(abs(r.minY - (100 - 37.8 + 270)) < 1e-6)
        #expect(abs(r.maxY - (980 + 37.8 - 270)) < 1e-6)
        // Never beyond the base reach.
        let tall = ZoomShotPlanner.boundedReach(reach, to: CGRect(x: 200, y: 0, width: 1200, height: 1080),
                                                half: half)
        #expect(tall.minY == 270 && tall.maxY == 810)
    }

    @Test func aWindowSmallerThanTheViewIsCentred() {
        let r = ZoomShotPlanner.boundedReach(reach, to: CGRect(x: 600, y: 300, width: 800, height: 400),
                                             half: half)
        #expect(r == CGRect(x: 1000, y: 500, width: 0, height: 0))
        // …as far as the content allows.
        let corner = ZoomShotPlanner.boundedReach(reach, to: CGRect(x: 0, y: 0, width: 300, height: 200),
                                                  half: half)
        #expect(corner == CGRect(x: 480, y: 270, width: 0, height: 0))
    }

    @Test func anAreaThatOnlyJustFitsIsKeptWhole() {
        // 900 wide in a 960 view: fits, but not with 67 px to spare each side.
        let r = ZoomShotPlanner.boundedReach(reach, to: CGRect(x: 500, y: 300, width: 900, height: 400),
                                             half: half)
        // The view may sit anywhere that still holds all of it, neither end
        // closer than 2% of the half view to the edge: 929.6…970.4.
        #expect(abs(r.minX - 929.6) < 1e-6 && abs(r.maxX - 970.4) < 1e-6)
        // Nearly as wide as the view: centred, both ends just inside it.
        let full = ZoomShotPlanner.boundedReach(reach, to: CGRect(x: 500, y: 300, width: 936, height: 400),
                                                half: half)
        #expect(abs(full.minX - 968) < 1e-6 && full.width == 0)
    }

    @Test func anAxisThatCannotPanIsLeftAlone() {
        // View taller than the content: the base reach is inverted on y.
        let base = CGRect(x: 480, y: 600, width: 960, height: -120)
        let r = ZoomShotPlanner.boundedReach(base, to: CGRect(x: 200, y: 100, width: 1200, height: 300),
                                             half: half)
        #expect(r.origin.y == 600 && r.size.height == -120)
    }

    // MARK: - Planner

    private func plan(_ cursor: (Double) -> CGPoint, end: Double,
                      bound: ((Double) -> CGRect?)?) -> [PlannedShot] {
        ZoomShotPlanner.shots(cursor: cursor, begin: 0, end: end, start: nil, half: half,
                              tuning: tuning, reach: reach, breaks: [], step: step, bound: bound)
    }
    private func inHardMargin(_ p: CGPoint, _ c: CGPoint) -> Bool {
        abs(Double(p.x - c.x)) <= 0.92 * 480 + 1 && abs(Double(p.y - c.y)) <= 0.92 * 270 + 1
    }
    /// Dwells 2 s at each of the points in turn, hopping in 0.2 s.
    private func visiting(_ points: [CGPoint]) -> (Double) -> CGPoint {
        { t in
            let i = min(Int(t / 2), points.count - 1)
            let into = t - Double(i) * 2
            guard i > 0, into < 0.2 else { return points[i] }
            let a = points[i - 1], b = points[i], f = into / 0.2
            return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
    }

    @Test func roamingInsideASmallWindowKeepsTheFrameOnIt() {
        let cursor = visiting([CGPoint(x: 700, y: 400), CGPoint(x: 1300, y: 700),
                               CGPoint(x: 650, y: 720), CGPoint(x: 1350, y: 350)])
        let shots = plan(cursor, end: 8) { _ in self.win }
        #expect(!shots.isEmpty)
        for s in shots {
            #expect(abs(s.center.x - 1000) < 1e-6)                 // narrower than the view
            #expect(s.center.y >= 532.2 - 1e-6 && s.center.y <= 567.8 + 1e-6)
        }
        // The pointer is in frame during every hold.
        for (i, s) in shots.enumerated() {
            let until = i + 1 < shots.count ? shots[i + 1].tExit : 8
            var t = s.tArrive
            while t < until { #expect(inHardMargin(cursor(t), s.center)); t += step }
        }
        // Unbound, the same path pans across the window.
        let free = plan(cursor, end: 8, bound: nil)
        #expect(free.contains { abs($0.center.x - 1000) > 100 })
    }

    @Test func steppingJustOutsideTheWindowOnlyWidensTheFrame() {
        let big = CGRect(x: 200, y: 100, width: 1200, height: 880)
        let inside: (Double) -> CGPoint = { _ in CGPoint(x: 1390, y: 500) }
        let stepsOut: (Double) -> CGPoint = { t in CGPoint(x: t < 2 ? 1390 : 1420, y: 500) }
        let a = plan(inside, end: 5) { _ in big }
        let b = plan(stepsOut, end: 5) { _ in big }
        #expect(a.count == 1 && b.count == 1)
        #expect(abs(a[0].center.x - 987.2) < 1e-6)
        #expect(abs(b[0].center.x - 1007.2) < 1e-6)
        #expect(inHardMargin(CGPoint(x: 1420, y: 500), b[0].center))
    }

    @Test func aPointerAwayFromTheWindowIsNotHeldToIt() {
        let cursor: (Double) -> CGPoint = { _ in CGPoint(x: 1700, y: 900) }
        let small = CGRect(x: 200, y: 100, width: 600, height: 500)
        #expect(plan(cursor, end: 4) { _ in small } == plan(cursor, end: 4, bound: nil))
    }

    @Test func aWindowChangeUnderAStillPointerIsOneEasedMove() {
        let big = CGRect(x: 200, y: 100, width: 1200, height: 880)
        let cursor: (Double) -> CGPoint = { _ in CGPoint(x: 1350, y: 500) }
        let shots = plan(cursor, end: 6) { $0 < 3 ? big : nil }
        #expect(shots.count == 2)
        #expect(abs(shots[0].center.x - 987.2) < 1e-6)
        #expect(abs(shots[1].center.x - 1350) < 1e-6)
        #expect(abs(shots[1].tExit - 3) < step && shots[1].tExit == shots[1].tArrive)
        #expect(!shots[1].isCut)
        #expect(shots[1].aim == shots[0].aim)
    }

    @Test func aChangeTooSmallToSeeMakesNoMove() {
        let big = CGRect(x: 200, y: 100, width: 1200, height: 880)
        var nudged = big
        nudged.size.width += 8
        let cursor: (Double) -> CGPoint = { _ in CGPoint(x: 1350, y: 500) }
        #expect(plan(cursor, end: 6) { $0 < 3 ? big : nudged }.count == 1)
    }

    @Test func aBlipBackToTheSameWindowIsNoChange() {
        let big = CGRect(x: 200, y: 100, width: 1200, height: 880)
        let cursor: (Double) -> CGPoint = { t in CGPoint(x: t < 2 ? 1420 : 1390, y: 500) }
        // The window drops out for 0.2 s (too short to re-frame for).
        let shots = plan(cursor, end: 6) { $0 >= 3 && $0 < 3.2 ? nil : big }
        #expect(shots.count == 1)
        #expect(abs(shots[0].center.x - 1007.2) < 1e-6)
    }

    @Test func aWindowChangeRightAfterLandingAppliesFromTheLanding() {
        let big = CGRect(x: 200, y: 100, width: 1200, height: 880)
        let cursor: (Double) -> CGPoint = { _ in CGPoint(x: 1350, y: 500) }
        // The tracker reported the window a moment late.
        let shots = plan(cursor, end: 6) { $0 < 0.1 ? nil : big }
        #expect(shots.count == 1)
        #expect(abs(shots[0].center.x - 987.2) < 1e-6)
    }

    @Test func noWindowIsIdenticalToPointerOnlyPlanning() {
        let cursor = visiting([CGPoint(x: 300, y: 300), CGPoint(x: 1500, y: 800),
                               CGPoint(x: 900, y: 200), CGPoint(x: 1700, y: 950)])
        #expect(plan(cursor, end: 8) { _ in nil } == plan(cursor, end: 8, bound: nil))
    }

    @Test func aBoundStillFramesWhatTheShotLeansToward() {
        // A menu opens below a small window: it stays in the allowed area.
        let small = CGRect(x: 700, y: 300, width: 500, height: 300)
        let menu = CGRect(x: 800, y: 560, width: 200, height: 300)
        let cursor: (Double) -> CGPoint = { _ in CGPoint(x: 850, y: 580) }
        let shots = ZoomShotPlanner.shots(
            cursor: cursor, begin: 0, end: 4, start: nil, half: half, tuning: tuning,
            reach: reach, breaks: [], step: step, lean: { _ in menu }, bound: { _ in small })
        #expect(shots.count == 1)
        // Window ∪ menu spans y 300…860: the view (540 tall) can reach the menu.
        #expect(shots[0].center.y + 270 >= 860 - 1)
    }

    // MARK: - Track

    private func samples(end: Double, _ path: (Double) -> CGPoint) -> [CursorSample] {
        var s: [CursorSample] = []
        var k = 0
        while Double(k) / 60 <= end {
            s.append(CursorSample(t: Double(k) / 60, p: path(Double(k) / 60), cursor: "arrow"))
            k += 1
        }
        return s
    }

    @Test func trackStaysOnTheWindowAndKeepsThePointerInFrame() {
        let cursor = visiting([CGPoint(x: 700, y: 400), CGPoint(x: 1300, y: 700),
                               CGPoint(x: 650, y: 720), CGPoint(x: 1350, y: 350)])
        let s = samples(end: 8, cursor)
        let block = [ZoomBlock(begin: 0, end: 8, scale: 2)]
        var cfg = AutoZoomConfig()
        cfg.windows = [WindowSpan(begin: 0, end: 8, rect: win)]
        let bound = AutoZoomTrack.build(blocks: block, cursorSamples: s, sourceSize: hd, config: cfg)
        for k in bound where k.weight > 0.999 {
            #expect(abs(k.focusX - 1000) < 1)
            #expect(k.focusY >= 532.2 - 1 && k.focusY <= 567.8 + 1)
            #expect(inHardMargin(cursor(k.t), CGPoint(x: k.focusX, y: k.focusY)))
        }
        // Without window data: exactly the pointer-only track.
        let plain = AutoZoomTrack.build(blocks: block, cursorSamples: s, sourceSize: hd)
        #expect(plain.contains { abs($0.focusX - 1000) > 100 })
    }

    @Test func aWindowThePointerNeverNearsChangesNothing() {
        // Includes shots pinned at the picture's edge, where centre ≠ aim.
        let cursor = visiting([CGPoint(x: 1700, y: 10), CGPoint(x: 1200, y: 600),
                               CGPoint(x: 1850, y: 1070), CGPoint(x: 1100, y: 20)])
        let s = samples(end: 8, cursor)
        let block = [ZoomBlock(begin: 0, end: 8, scale: 2)]
        var cfg = AutoZoomConfig()
        cfg.windows = [WindowSpan(begin: 0, end: 8,
                                  rect: CGRect(x: 100, y: 300, width: 400, height: 400))]
        #expect(AutoZoomTrack.build(blocks: block, cursorSamples: s, sourceSize: hd, config: cfg)
                == AutoZoomTrack.build(blocks: block, cursorSamples: s, sourceSize: hd))
    }

    @Test func anOverflowBlockIsNeverBound() {
        let cursor = visiting([CGPoint(x: 700, y: 400), CGPoint(x: 1300, y: 700)])
        let s = samples(end: 4, cursor)
        let block = [ZoomBlock(begin: 0, end: 4, scale: 2, overflow: true)]
        var cfg = AutoZoomConfig()
        cfg.windows = [WindowSpan(begin: 0, end: 4, rect: win)]
        #expect(AutoZoomTrack.build(blocks: block, cursorSamples: s, sourceSize: hd, config: cfg)
                == AutoZoomTrack.build(blocks: block, cursorSamples: s, sourceSize: hd))
    }

    @Test func aMoveOutOfABoundShotKeepsThePointerInFrame() {
        // Window narrower than the view: the frame sits on its centre while the
        // pointer works near its right edge, then leaves for the far left.
        let narrow = CGRect(x: 900, y: 200, width: 800, height: 700)
        let cursor: (Double) -> CGPoint = { t in
            if t < 3 { return CGPoint(x: 1650, y: 540) }
            if t < 3.3 { return CGPoint(x: 1650 - (t - 3) / 0.3 * 1350, y: 540) }
            return CGPoint(x: 300, y: 540)
        }
        let s = samples(end: 7, cursor)
        var cfg = AutoZoomConfig()
        cfg.windows = [WindowSpan(begin: 0, end: 3.1, rect: narrow)]
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 7, scale: 2)],
                                        cursorSamples: s, sourceSize: hd, config: cfg)
        // Until the pointer starts to leave, it is inside the picture.
        for k in track where k.weight > 0.999 && k.t <= 3 {
            #expect(abs(Double(cursor(k.t).x) - k.focusX) <= 480)
        }
    }

    // MARK: - Suggester

    private var config: AutoZoomSuggestConfig {
        var c = AutoZoomSuggestConfig(rampIn: 0.475, rampOut: 0.475)
        c.viewSize = hd
        c.defaultScale = 2
        return c
    }
    private func suggest(_ activity: ZoomActivity, windows: [WindowSpan],
                         reveals: [Reveal] = []) -> [ZoomBlock] {
        AutoZoomSuggester.suggest(activity: activity, cursorSamples: [], span: 0...60,
                                  sourceSize: hd, cuts: [], config: config, reveals: reveals,
                                  windows: windows)
    }
    private func clicks(_ times: [Double], at p: CGPoint) -> [ClickSample] {
        times.map { ClickSample(t: $0, p: p) }
    }
    private let dialog = CGRect(x: 600, y: 300, width: 600, height: 400)

    @Test func aRunInsideASmallWindowZoomsToFitIt() {
        let activity = ZoomActivity(clicks: clicks([5, 6, 7], at: CGPoint(x: 900, y: 500)))
        let blocks = suggest(activity, windows: [WindowSpan(begin: 0, end: 20, rect: dialog)])
        // 0.86 × min(1920/600, 1080/400) = 2.322, rounded down.
        #expect(blocks.map(\.scale) == [2.3])
    }

    @Test func aLargeWindowSetsNoScale() {
        let activity = ZoomActivity(clicks: clicks([5, 6, 7], at: CGPoint(x: 900, y: 500)))
        let large = CGRect(x: 100, y: 50, width: 1500, height: 900)
        #expect(suggest(activity, windows: [WindowSpan(begin: 0, end: 20, rect: large)])
            .map(\.scale) == [nil])
    }

    @Test func oneClickInADialogDoesNotRescaleARun() {
        let activity = ZoomActivity(
            clicks: clicks([5, 6], at: CGPoint(x: 1500, y: 900))      // outside the dialog
                + clicks([7], at: CGPoint(x: 900, y: 500)))
        #expect(suggest(activity, windows: [WindowSpan(begin: 0, end: 20, rect: dialog)])
            .map(\.scale) == [nil])
    }

    @Test func aRevealInTheWindowCanOnlyLowerTheScale() {
        let p = CGPoint(x: 700, y: 400)
        let activity = ZoomActivity(clicks: clicks([5, 6], at: p))
        let windows = [WindowSpan(begin: 0, end: 20, rect: dialog)]
        // A wide panel opens: fitting it needs less zoom than fitting the dialog.
        let wide = Reveal(t: 5, click: p, rect: CGRect(x: 700, y: 400, width: 800, height: 300))
        let s = suggest(activity, windows: windows, reveals: [wide]).first?.scale ?? 0
        #expect(s < 2.3 && s >= 1.5)
    }

    @Test func typingInASmallWindowHoldsTheWindowsFraming() {
        let activity = ZoomActivity(clicks: clicks([1.5], at: CGPoint(x: 650, y: 350)),
                                    typing: [TimeSpan(begin: 2, end: 6)])
        let blocks = suggest(activity, windows: [WindowSpan(begin: 0, end: 20, rect: dialog)])
        let typing = blocks.first { $0.mode == .manual }
        // At 2.3× the view (835×470) is larger than the dialog plus its margin
        // on both axes: the frame sits on the dialog's centre, not on the click.
        #expect(abs((typing?.focusX ?? 0) - 900.0 / 1920) < 1e-6)
        #expect(abs((typing?.focusY ?? 0) - 500.0 / 1080) < 1e-6)
        // Without window data it holds on the click, as before.
        let plain = suggest(activity, windows: []).first { $0.mode == .manual }
        #expect(abs((plain?.focusX ?? 0) - 650.0 / 1920) < 1e-6)
    }

    @Test func theClickThatOpenedTheDialogDoesNotVetoItsScale() {
        let activity = ZoomActivity(
            clicks: clicks([5], at: CGPoint(x: 1500, y: 900))          // the button, outside
                + clicks([6, 7], at: CGPoint(x: 900, y: 500)))
        #expect(suggest(activity, windows: [WindowSpan(begin: 5.5, end: 20, rect: dialog)])
            .map(\.scale) == [2.3])
    }

    @Test func aBlockKeepingItsOwnScaleFramesTypingForThatScale() {
        let activity = ZoomActivity(clicks: clicks([1.5], at: CGPoint(x: 650, y: 350)),
                                    typing: [TimeSpan(begin: 2, end: 6)])
        var c = config
        c.fixedScale = 4          // view 480×270: smaller than the dialog
        let typing = AutoZoomSuggester.suggest(
            activity: activity, cursorSamples: [], span: 0...60, sourceSize: hd, cuts: [],
            config: c, windows: [WindowSpan(begin: 0, end: 20, rect: dialog)])
            .first { $0.mode == .manual }
        // The click stays in the frame: |click − centre| within the half view.
        let fx = (typing?.focusX ?? 0) * 1920, fy = (typing?.focusY ?? 0) * 1080
        #expect(abs(fx - 650) <= 240 && abs(fy - 350) <= 135)
        // …and the frame does not show past the dialog's margin.
        #expect(fx - 240 >= 600 - 0.07 * 480 - 1e-6)
    }

    @Test func aWindowAwayFromTheClicksChangesNothing() {
        let activity = ZoomActivity(clicks: clicks([5, 6, 20], at: CGPoint(x: 900, y: 500)),
                                    typing: [TimeSpan(begin: 21, end: 25)])
        let elsewhere = [WindowSpan(begin: 0, end: 60,
                                    rect: CGRect(x: 1300, y: 600, width: 500, height: 400))]
        let a = suggest(activity, windows: elsewhere)
        let b = suggest(activity, windows: [])
        #expect(!a.isEmpty)
        #expect(a.map { [$0.begin, $0.end, $0.scale ?? -1, $0.focusX ?? -1, $0.focusY ?? -1] }
                == b.map { [$0.begin, $0.end, $0.scale ?? -1, $0.focusX ?? -1, $0.focusY ?? -1] })
    }
}
