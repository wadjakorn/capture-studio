import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

/// Auto-scale zoom blocks: one block whose zoom changes by itself, within a
/// range, to fit the window it works in and what clicks open.
@Suite struct DynamicZoomTests {
    private let hd = CGSize(width: 1920, height: 1080)
    // Fit of a w×h subject in the 1920×1080 view: 0.86 × min(1920/w, 1080/h), floored to 0.05.
    private let dialog = CGRect(x: 600, y: 300, width: 600, height: 400)      // fit 2.30
    private let big = CGRect(x: 100, y: 50, width: 1000, height: 600)         // fit 1.50 (1.548)
    private let huge = CGRect(x: 100, y: 50, width: 1500, height: 900)        // fit 1.03: nothing to fit

    private func samples(end: Double, _ path: (Double) -> CGPoint) -> [CursorSample] {
        var s: [CursorSample] = []
        var k = 0
        while Double(k) / 60 <= end {
            s.append(CursorSample(t: Double(k) / 60, p: path(Double(k) / 60), cursor: "arrow"))
            k += 1
        }
        return s
    }
    private func block(_ begin: Double, _ end: Double, scale: Double? = nil,
                       _ auto: ZoomAutoScale? = ZoomAutoScale(), show: ZoomShow? = nil) -> ZoomBlock {
        ZoomBlock(begin: begin, end: end, scale: scale, auto: auto, show: show)
    }
    private func expand(_ blocks: [ZoomBlock], windows: [WindowSpan] = [], reveals: [Reveal] = [],
                        cursor: [CursorSample] = []) -> ZoomAutoScaler.Expansion {
        var cfg = AutoZoomConfig()
        cfg.windows = windows
        cfg.reveals = reveals
        return ZoomAutoScaler.expand(blocks: blocks, cursor: cursor, sourceSize: hd, config: cfg)
    }
    /// [begin, end, scale] per piece.
    private func shape(_ x: ZoomAutoScaler.Expansion) -> [[Double]] {
        x.blocks.map { [$0.begin, $0.end, $0.scale ?? -1] }
    }

    // MARK: - Model

    @Test func autoScaleSurvivesARoundTripAndOddData() throws {
        let b = ZoomBlock(begin: 1, end: 5, scale: 2,
                          auto: ZoomAutoScale(min: 1.2, max: 4, fitReveals: false), show: .both)
        let back = try JSONDecoder().decode(ZoomBlock.self, from: JSONEncoder().encode(b))
        #expect(back == b)
        #expect(back.show == .both && back.auto?.fitReveals == false)
        // No key → fixed scale.
        let plain = try JSONDecoder().decode(
            ZoomBlock.self, from: Data(#"{"id":"\#(UUID().uuidString)","begin":0,"end":1}"#.utf8))
        #expect(plain.auto == nil && plain.show == nil)
        // Never chosen: the pointer for one level, "decide for me" with a range.
        #expect(plain.effectiveShow == .pointer)
        #expect(ZoomBlock(begin: 0, end: 1, auto: ZoomAutoScale()).effectiveShow == .auto)
        // Missing fields, odd values, a reversed and out-of-range range.
        let odd = try JSONDecoder().decode(
            ZoomAutoScale.self, from: Data(#"{"min":9,"max":0.5,"fitReveals":"x"}"#.utf8))
        #expect(odd == ZoomAutoScale(min: 1.1, max: 6, fitReveals: true))
        // A project saved while "leave" lived inside the range: it becomes Show,
        // until Show is chosen; it is not written back.
        let old = try JSONDecoder().decode(ZoomBlock.self, from: Data(
            #"{"id":"\#(UUID().uuidString)","begin":0,"end":1,"auto":{"min":1.1,"max":3,"leave":"both"}}"#.utf8))
        #expect(old.show == .both)
        // …and survives a save: written as Show, not as the old key.
        let saved = try JSONEncoder().encode(old)
        #expect(!String(decoding: saved, as: UTF8.self).contains("leave"))
        #expect(try JSONDecoder().decode(ZoomBlock.self, from: saved) == old)
        // An unknown Show from a later version reads as "decide for me".
        #expect(try JSONDecoder().decode(ZoomShow.self, from: Data(#""someday""#.utf8)) == .auto)
        // Not even an object: the defaults, not a failed project.
        #expect(try JSONDecoder().decode(ZoomAutoScale.self, from: Data("7".utf8)) == ZoomAutoScale())
        #expect(try JSONDecoder().decode(ZoomAutoScale.self, from: Data("{}".utf8)) == ZoomAutoScale())
    }

    // MARK: - Expansion

    @Test func fixedBlocksAreLeftAlone() {
        let blocks = [block(0, 5, scale: 2, nil), ZoomBlock(begin: 6, end: 9, mode: .manual,
                                                            auto: ZoomAutoScale())]
        let x = expand(blocks, windows: [WindowSpan(begin: 0, end: 9, rect: dialog, id: 1)])
        #expect(x.blocks == blocks)
        #expect(x.softSeams.isEmpty && x.pointerHolds.isEmpty)
    }

    @Test func withNothingToFitARangeBlockIsItsOwnLevelInsideTheRange() {
        #expect(shape(expand([block(0, 6)])) == [[0, 6, 2.0]])
        #expect(shape(expand([block(0, 6, scale: 1.3)])) == [[0, 6, 1.5]])
        #expect(shape(expand([block(0, 6, scale: 4)])) == [[0, 6, 3.0]])
        // …and renders exactly like the fixed block.
        let s = samples(end: 6) { t in CGPoint(x: 400 + 150 * t, y: 500) }
        #expect(AutoZoomTrack.build(blocks: [block(0, 6, scale: 2.4)], cursorSamples: s, sourceSize: hd)
                == AutoZoomTrack.build(blocks: [block(0, 6, scale: 2.4, nil)], cursorSamples: s,
                                       sourceSize: hd))
    }

    @Test func theScaleFitsTheWindowTheBlockWorksIn() {
        let x = expand([block(0, 12)], windows: [WindowSpan(begin: 0, end: 6, rect: dialog, id: 1),
                                                 WindowSpan(begin: 6, end: 12, rect: big, id: 2)])
        #expect(shape(x) == [[0, 6, 2.3], [6, 12, 1.5]])
        #expect(x.softSeams == [6])
        // A window too large for the least zoom gets the least zoom.
        #expect(shape(expand([block(0, 6)], windows: [WindowSpan(begin: 0, end: 6, rect: huge, id: 1)]))
                == [[0, 6, 1.5]])
        // The range caps it.
        let tight = ZoomAutoScale(min: 1.5, max: 1.8)
        #expect(shape(expand([block(0, 6, tight)],
                             windows: [WindowSpan(begin: 0, end: 6, rect: dialog, id: 1)]))
                == [[0, 6, 1.8]])
        // A range fits the window under the pointer whatever the block shows.
        #expect(shape(expand([block(0, 6, show: .pointer)],
                             windows: [WindowSpan(begin: 0, end: 6, rect: dialog, id: 1)]))
                == [[0, 6, 2.3]])
    }

    @Test func oneZoomLevelCanStillHoldAWindow() {
        let long = trip(6)
        func run(_ show: ZoomShow?) -> ZoomAutoScaler.Expansion {
            expand([block(0, long.end, scale: 1.4, nil, show: show)], windows: long.windows,
                   cursor: long.cursor)
        }
        // The pointer (or never chosen): the block is not touched at all.
        for show in [ZoomShow?.none, .pointer] {
            let plain = block(0, long.end, scale: 1.4, nil, show: show)
            let x = expand([plain], windows: long.windows, cursor: long.cursor)
            #expect(x.blocks == [plain])
            #expect(x.windows == long.windows && x.pointerHolds.isEmpty && x.softSeams.isEmpty)
        }
        // The window: one level throughout, the pointer held inside it.
        let stay = run(.window)
        #expect(shape(stay) == [[0, 16, 1.4]])
        #expect(stay.softSeams.isEmpty)
        #expect(stay.pointerHolds == [WindowSpan(begin: 5, end: 11, rect: dialog, id: 1)])
        // Window and pointer: both fit at 1.4× (they need 1.5), so both are held.
        let both = run(.both)
        #expect(shape(both) == [[0, 16, 1.4]])
        #expect(both.windows.map(\.rect) == [dialog, CGRect(x: 600, y: 300, width: 900, height: 600),
                                              dialog])
        // …but not at 2.4×: the pointer is followed, still at 2.4×.
        let tight = expand([block(0, long.end, scale: 2.4, nil, show: .both)],
                           windows: long.windows, cursor: long.cursor)
        #expect(shape(tight) == [[0, 16, 2.4]])
        #expect(tight.windows.map(\.rect) == [dialog, dialog])
    }

    @Test func windowAndPointerHoldsBothWhenTheyOnlyJustFit() {
        // From the user's recording (2704×1756): the window's corner is dragged
        // out to the far side of the screen. Window ∪ pointer is 2326×1538 — it
        // fits the 1.1× view (2458×1596) edge to edge, though not with the margin.
        let source = CGSize(width: 2704, height: 1756)
        let window = CGRect(x: 190, y: 64, width: 1560, height: 1120)
        let cursor = samples(end: 9) { t in
            let f = min(max((t - 3) / 1.0, 0), 1)
            return t < 5 ? CGPoint(x: 1740 + 776 * f, y: 1170 + 432 * f) : CGPoint(x: 1000, y: 600)
        }
        var cfg = AutoZoomConfig()
        cfg.windows = [WindowSpan(begin: 0, end: 3, rect: window, id: 1),
                       WindowSpan(begin: 5, end: 9, rect: window, id: 1)]
        let b = ZoomBlock(begin: 0, end: 9, scale: 1.3, auto: ZoomAutoScale(min: 1.1, max: 3.5),
                          show: .both)
        let x = ZoomAutoScaler.expand(blocks: [b], cursor: cursor, sourceSize: source, config: cfg)
        // Held on both for the trip…
        let union = CGRect(x: 190, y: 64, width: 2326, height: 1538)
        #expect(WindowHints.window(at: 4, in: x.windows) == union)
        #expect(ZoomAutoScaler.scale(at: 4, in: x) == 1.1)
        // …and the picture really contains both: nothing cut off on either side.
        let track = AutoZoomTrack.build(blocks: [b], cursorSamples: cursor, sourceSize: source,
                                        config: cfg)
        let z = AutoZoomTrack.sample(at: 4.5, track: track)
        let halfW = 2704 / (2 * Double(z.scale)), halfH = 1756 / (2 * Double(z.scale))
        #expect(Double(z.focus.x) - halfW <= 190 + 1 && Double(z.focus.x) + halfW >= 2516 - 1)
        #expect(Double(z.focus.y) - halfH <= 64 + 1 && Double(z.focus.y) + halfH >= 1602 - 1)
    }

    @Test func aShortTripStillShowsBothWhenAskedTo() {
        // One second outside the window: too short for "decide for me" to zoom
        // for, but "window and pointer" was asked for.
        let short = trip(1)
        func scales(_ show: ZoomShow) -> [[Double]] {
            shape(expand([block(0, short.end, show: show)], windows: short.windows,
                         cursor: short.cursor))
        }
        #expect(scales(.both) == [[0, 5, 2.3], [5, 6, 1.5], [6, 11, 2.3]])
        #expect(scales(.auto) == [[0, 11, 2.3]])
    }

    @Test func theWindowMeansOnlyTheWindow() {
        // The pointer works near the left edge of a window larger than the
        // view; a click there opens something that reaches out past the
        // window. Showing "the window", the frame is not pulled toward it.
        let source = CGSize(width: 2704, height: 1756)
        let window = CGRect(x: 478, y: 298, width: 1900, height: 1200)
        let p = CGPoint(x: 600, y: 800)
        let cursor = samples(end: 8) { _ in p }
        var cfg = AutoZoomConfig()
        cfg.windows = [WindowSpan(begin: 0, end: 8, rect: window, id: 1)]
        cfg.reveals = [Reveal(t: 0.5, click: p, rect: CGRect(x: 60, y: 700, width: 500, height: 200))]
        func centreX(_ show: ZoomShow) -> Double {
            let track = AutoZoomTrack.build(
                blocks: [ZoomBlock(begin: 0, end: 8, scale: 2, show: show)],
                cursorSamples: cursor, sourceSize: source, config: cfg)
            return Double(AutoZoomTrack.sample(at: 4, track: track).focus.x)
        }
        // View 1352 wide at 2×. Held to the window: its left edge (478) less the
        // margin (95) → centre no further left than 1059.
        #expect(centreX(.window) >= 1059 - 1)
        // Following the pointer, the frame leans over to what opened.
        #expect(centreX(.pointer) < centreX(.window) - 100)
        // And "the window" does not zoom out for it either.
        let ranged = ZoomBlock(begin: 0, end: 8, auto: ZoomAutoScale(min: 1.1, max: 3.5),
                               show: .window)
        var both = ranged
        both.show = .auto
        func scales(_ b: ZoomBlock) -> [Double] {
            ZoomAutoScaler.expand(blocks: [b], cursor: cursor, sourceSize: source, config: cfg)
                .blocks.compactMap(\.scale)
        }
        #expect(scales(ranged) == [1.2])          // 0.86 × min(2704/1900, 1756/1200)
        #expect(scales(both).contains { $0 < 1.2 })
    }

    @Test func aClickDuringATripDoesNotCancelShowingBoth() {
        // "Window and pointer", a one-second trip, and the click out there
        // opens something: the trip still zooms out for both.
        let short = trip(1)
        let reveal = Reveal(t: 5.4, click: CGPoint(x: 1500, y: 900),
                            rect: CGRect(x: 1300, y: 700, width: 300, height: 250))
        let x = expand([block(0, short.end, show: .both)], windows: short.windows,
                       reveals: [reveal], cursor: short.cursor)
        #expect((ZoomAutoScaler.scale(at: 5.5, in: x) ?? 9) <= 1.5)
        #expect(WindowHints.window(at: 5.5, in: x.windows)
                == CGRect(x: 600, y: 300, width: 900, height: 600))
    }

    @Test func aFlickOutsideDoesNotPumpTheZoom() {
        let flick = trip(0.3)
        #expect(shape(expand([block(0, flick.end, show: .both)], windows: flick.windows,
                             cursor: flick.cursor)) == [[0, 10.3, 2.3]])
    }

    @Test func theStoryIsToldForWhatPlays() {
        // The pointer spends a long stretch over a big window — but that stretch
        // is cut away. What plays is the dialog, and the story says so, in
        // master time.
        let windows = [WindowSpan(begin: 0, end: 4, rect: dialog, id: 1),
                       WindowSpan(begin: 4, end: 16, rect: big, id: 2),
                       WindowSpan(begin: 16, end: 20, rect: dialog, id: 1)]
        var cfg = AutoZoomConfig()
        cfg.windows = windows
        let b = block(0, 20, show: .window)
        let cursor = samples(end: 20) { _ in CGPoint(x: 900, y: 500) }
        let uncut = ZoomBlockSummary.story(of: b, in: [b], cursor: cursor, sourceSize: hd, config: cfg)
        let cut = ZoomBlockSummary.story(of: b, in: [b], cursor: cursor, sourceSize: hd, config: cfg,
                                         cuts: [4.0..<16.0])
        // Uncut, the big window is home (12 s of 20) and the dialog a trip.
        #expect(uncut.phases.map(\.kind) == [.holdWindow, .window, .holdWindow])
        // Cut, only the dialog is left: one stretch, spanning the cut in master time.
        #expect(cut.phases == [ZoomPhase(begin: 0, end: 20, kind: .window, scale: 2.3)])
    }

    @Test func holdingAWindowStopsAtThePicturesEdge() {
        // The block's own edge setting says "keep centred"; a held window wins.
        let long = trip(6)
        var b = block(0, long.end, show: .window)
        b.overflow = true
        let x = expand([b], windows: long.windows, cursor: long.cursor)
        #expect(x.blocks.allSatisfy { $0.overflow == false })
        #expect(!x.pointerHolds.isEmpty)
        // "Decide for me" respects it: nothing is held.
        var a = block(0, long.end, show: .auto)
        a.overflow = true
        let y = expand([a], windows: trip(3).windows, cursor: trip(3).cursor)
        #expect(y.blocks.allSatisfy { $0.overflow == true })
    }

    // The pointer works in the dialog, goes to (1500, 900) for `away` seconds, comes back.
    private func trip(_ away: Double) -> (windows: [WindowSpan], cursor: [CursorSample], end: Double) {
        let end = 5 + away + 5
        let windows = [WindowSpan(begin: 0, end: 5, rect: dialog, id: 1),
                       WindowSpan(begin: 5 + away, end: end, rect: dialog, id: 1)]
        let cursor = samples(end: end) { t in
            t >= 5 && t < 5 + away ? CGPoint(x: 1500, y: 900) : CGPoint(x: 900, y: 500)
        }
        return (windows, cursor, end)
    }

    @Test func aShortTripOutsideShowsBothAndALongOneFollowsThePointer() {
        // Dialog ∪ pointer = (600,300)…(1500,900): 900×600 → fit 1.5.
        let short = trip(3)
        let a = expand([block(0, short.end)], windows: short.windows, cursor: short.cursor)
        #expect(shape(a) == [[0, 5, 2.3], [5, 8, 1.5], [8, 13, 2.3]])
        let both = CGRect(x: 600, y: 300, width: 900, height: 600)
        #expect(a.windows.map(\.rect) == [dialog, both, dialog])
        #expect(a.pointerHolds.isEmpty)

        let long = trip(6)
        let b = expand([block(0, long.end)], windows: long.windows, cursor: long.cursor)
        #expect(shape(b) == [[0, 5, 2.3], [5, 11, 2.0], [11, 16, 2.3]])
        #expect(b.windows.map(\.rect) == [dialog, dialog])
    }

    @Test func theBlockCanBeToldWhatToDoWhenThePointerLeaves() {
        let long = trip(6)
        func run(_ show: ZoomShow) -> ZoomAutoScaler.Expansion {
            expand([block(0, long.end, show: show)], windows: long.windows,
                   cursor: long.cursor)
        }
        #expect(shape(run(.both)) == [[0, 5, 2.3], [5, 11, 1.5], [11, 16, 2.3]])
        #expect(shape(run(.pointer)) == [[0, 5, 2.3], [5, 11, 2.0], [11, 16, 2.3]])
        // Stay on the window: one scale throughout, the pointer held inside it.
        let stay = run(.window)
        #expect(shape(stay) == [[0, 16, 2.3]])
        #expect(stay.pointerHolds == [WindowSpan(begin: 5, end: 11, rect: dialog, id: 1)])
        #expect(stay.windows.map(\.rect) == [dialog, dialog, dialog])
    }

    @Test func showBothGivesWayWhenBothCannotFit() {
        // Least zoom 2: dialog ∪ pointer needs 1.5 → the pointer is followed.
        let short = trip(3)
        let x = expand([block(0, short.end, ZoomAutoScale(min: 2, max: 3), show: .both)],
                       windows: short.windows, cursor: short.cursor)
        #expect(shape(x) == [[0, 5, 2.3], [5, 8, 2.0], [8, 13, 2.3]])
        #expect(x.windows.map(\.rect) == [dialog, dialog])
    }

    @Test func aGapInTheDataWithThePointerStillInTheWindowIsNotATrip() {
        let windows = [WindowSpan(begin: 0, end: 5, rect: dialog, id: 1),
                       WindowSpan(begin: 7, end: 12, rect: dialog, id: 1)]
        let cursor = samples(end: 12) { _ in CGPoint(x: 900, y: 500) }
        let x = expand([block(0, 12)], windows: windows, cursor: cursor)
        #expect(shape(x) == [[0, 12, 2.3]])
        #expect(x.windows.map { [$0.begin, $0.end] } == [[0, 5], [5, 7], [7, 12]])
    }

    @Test func theSameWindowMovedIsStillHome() {
        var moved = dialog
        moved.origin.x += 300
        let windows = [WindowSpan(begin: 0, end: 5, rect: dialog, id: 1),
                       WindowSpan(begin: 5, end: 12, rect: moved, id: 1)]
        let x = expand([block(0, 12)], windows: windows)
        #expect(shape(x) == [[0, 12, 2.3]])
    }

    @Test func whatAClickOpensCanOnlyZoomOut() {
        let p = CGPoint(x: 700, y: 400)
        let windows = [WindowSpan(begin: 0, end: 12, rect: dialog, id: 1)]
        // Inside the dialog already: nothing changes.
        let inside = Reveal(t: 4, click: p, rect: CGRect(x: 700, y: 400, width: 200, height: 200))
        #expect(shape(expand([block(0, 12)], windows: windows, reveals: [inside])) == [[0, 12, 2.3]])
        // A panel reaching outside it: dialog ∪ panel = 900×400 → 1.8, for a while.
        let panel = Reveal(t: 4, click: p, rect: CGRect(x: 1100, y: 350, width: 400, height: 300))
        #expect(shape(expand([block(0, 12)], windows: windows, reveals: [panel]))
                == [[0, 4, 2.3], [4, 6.5, 1.8], [6.5, 12, 2.3]])
        // No window: a small reveal never zooms in past the base scale.
        let small = Reveal(t: 4, click: p, rect: CGRect(x: 700, y: 400, width: 300, height: 200))
        #expect(shape(expand([block(0, 12)], reveals: [small])) == [[0, 12, 2.0]])
        // "What a click opens" off.
        #expect(shape(expand([block(0, 12, ZoomAutoScale(fitReveals: false))], windows: windows,
                             reveals: [panel])) == [[0, 12, 2.3]])
    }

    @Test func changesAreKeptFewAndWorthSeeing() {
        // A second window for only 1.2 s: not worth a scale of its own.
        let brief = [WindowSpan(begin: 0, end: 5, rect: dialog, id: 1),
                     WindowSpan(begin: 5, end: 6.2, rect: big, id: 2),
                     WindowSpan(begin: 6.2, end: 12, rect: dialog, id: 1)]
        #expect(shape(expand([block(0, 12, show: .pointer)], windows: brief))
                == [[0, 12, 2.3]])
        // A 2 s zoom-in between two wider framings is not made.
        let peak = [WindowSpan(begin: 0, end: 5, rect: big, id: 2),
                    WindowSpan(begin: 5, end: 7, rect: dialog, id: 1),
                    WindowSpan(begin: 7, end: 12, rect: big, id: 2)]
        #expect(shape(expand([block(0, 12)], windows: peak)) == [[0, 12, 1.5]])
        // Scales within 15% are one — the lower.
        let wider = CGRect(x: 600, y: 300, width: 720, height: 440)      // fit 2.10
        let close = [WindowSpan(begin: 0, end: 6, rect: dialog, id: 1),
                     WindowSpan(begin: 6, end: 12, rect: wider, id: 2)]
        #expect(shape(expand([block(0, 12, show: .pointer)], windows: close))
                == [[0, 12, 2.1]])
    }

    @Test func splittingABlockChangesNothing() {
        let windows = [WindowSpan(begin: 0, end: 6, rect: dialog, id: 1),
                       WindowSpan(begin: 6, end: 12, rect: big, id: 2)]
        let whole = expand([block(0, 12)], windows: windows)
        let split = expand([block(0, 5.3), block(5.3, 12)], windows: windows)
        #expect(shape(split) == [[0, 5.3, 2.3], [5.3, 6, 2.3], [6, 12, 1.5]])
        #expect(split.softSeams == whole.softSeams)
        // …including a split right next to the scale change.
        let s = samples(end: 12) { t in t < 6 ? CGPoint(x: 900, y: 500) : CGPoint(x: 500, y: 300) }
        var cfg = AutoZoomConfig()
        cfg.windows = windows
        func scales(_ blocks: [ZoomBlock]) -> [Double] {
            let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: s, sourceSize: hd,
                                            config: cfg)
            return stride(from: 0.5, to: 11.5, by: 0.05).map {
                (Double(AutoZoomTrack.sample(at: $0, track: track).scale) * 1000).rounded() / 1000
            }
        }
        #expect(scales([block(0, 5.9), block(5.9, 12)]) == scales([block(0, 12)]))
        #expect(scales([block(0, 6.1), block(6.1, 12)]) == scales([block(0, 12)]))
    }

    @Test func resizingAWindowShowsAllOfIt() {
        // From the user's recording: a 2704×1756 capture, a 1120×748 pt window
        // dragged down to 780×560 by its corner between 1.0 and 2.2 s.
        let display = DisplayInfo(displayID: 1, pixelWidth: 2704, pixelHeight: 1756,
                                  pointWidth: 1352, pointHeight: 878, scaleFactor: 2,
                                  originX: 0, originY: 0)
        let source = CGSize(width: 2704, height: 1756)
        func l(_ t: Double, _ id: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> WindowLine {
            WindowLine(t: t, id: id, x: x, y: y, w: w, h: h)
        }
        let lines = [l(0.04, 7, 140, 71, 1120, 748), .none(t: 1.04), l(1.44, 7, 140, 71, 1120, 748),
                     l(2.04, 7, 268, 147, 992, 672), l(2.14, 7, 434, 259, 826, 560),
                     l(2.24, 7, 480, 259, 780, 560)]
        let spans = WindowHints.spans(lines: lines, display: display, sourceSize: source, duration: 7)
        let cursor = samples(end: 7) { t in
            let f = min(max((t - 1.0) / 1.2, 0), 1)       // on the top-left corner
            return CGPoint(x: (138 + 342 * f) * 2, y: (69 + 190 * f) * 2)
        }
        var cfg = AutoZoomConfig()
        cfg.windows = spans
        let x = ZoomAutoScaler.expand(
            blocks: [block(0, 7, scale: 1.75, ZoomAutoScale(min: 1.1, max: 3, fitReveals: false),
                                  show: .both)],
            cursor: cursor, sourceSize: source, config: cfg)
        // The large window: as far out as the range allows, through the resize;
        // then in on the small one.
        #expect(x.blocks.first?.scale == 1.1)
        #expect((x.blocks.first?.end ?? 0) >= 2.2)
        #expect(x.blocks.last?.scale == 1.3)
        // The frame is held to the whole window while it is being resized.
        let during = WindowHints.window(at: 1.8, in: x.windows)
        #expect(during?.contains(CGRect(x: 280, y: 142, width: 2240, height: 1496)) == true)
    }

    @Test func aSlowDriftIsNotOneScale() {
        // Fits 2.3, 2.1, 1.9, 1.7: each step is under 15%, the whole is not.
        func w(_ width: CGFloat, _ id: Int, _ t: Double) -> WindowSpan {
            WindowSpan(begin: t, end: t + 4,
                       rect: CGRect(x: 300, y: 300, width: width, height: 300), id: id)
        }
        let x = expand([block(0, 16, show: .pointer)],
                       windows: [w(700, 1, 0), w(770, 2, 4), w(850, 3, 8), w(950, 4, 12)])
        let scales = Set(x.blocks.compactMap(\.scale))
        #expect(scales.count >= 2)
        #expect((scales.max() ?? 0) / (scales.min() ?? 1) > 1.15)
    }

    @Test func theZoomComesBackAfterAClickNearTheBlocksEnd() {
        let p = CGPoint(x: 700, y: 400)
        let windows = [WindowSpan(begin: 0, end: 12, rect: dialog, id: 1)]
        let panel = Reveal(t: 7.2, click: p, rect: CGRect(x: 1100, y: 350, width: 400, height: 300))
        // 2.3 s back in the dialog at the end of the block: still zoomed to it.
        #expect(shape(expand([block(0, 12)], windows: windows, reveals: [panel]))
                == [[0, 7.2, 2.3], [7.2, 9.7, 1.8], [9.7, 12, 2.3]])
    }

    @Test func aRangeBetweenStepsStillFitsTheWindow() {
        // Raw fit of `big` is 1.548: a least zoom of 1.52 fits it.
        let x = expand([block(0, 6, ZoomAutoScale(min: 1.52, max: 3))],
                       windows: [WindowSpan(begin: 0, end: 6, rect: big, id: 1)])
        #expect(shape(x) == [[0, 6, 1.52]])
    }

    // MARK: - Track

    @Test func oneBlockZoomsDifferentlyForADialogAndALargeWindow() {
        let windows = [WindowSpan(begin: 0, end: 6, rect: dialog, id: 1),
                       WindowSpan(begin: 6, end: 12, rect: big, id: 2)]
        let cursor: (Double) -> CGPoint = { t in
            t < 6 ? CGPoint(x: 900, y: 500) : CGPoint(x: 500, y: 300)
        }
        var cfg = AutoZoomConfig()
        cfg.windows = windows
        let track = AutoZoomTrack.build(blocks: [block(0, 12)], cursorSamples: samples(end: 12, cursor),
                                        sourceSize: hd, config: cfg)
        func scale(_ t: Double) -> Double { Double(AutoZoomTrack.sample(at: t, track: track).scale) }
        #expect(abs(scale(3) - 2.3) < 1e-6)
        #expect(abs(scale(9) - 1.5) < 1e-6)
        // Eased between the two: never outside them, never a step.
        var prev = scale(5)
        var t = 5.0
        while t <= 7 {
            let s = scale(t)
            #expect(s <= 2.3 + 1e-6 && s >= 1.5 - 1e-6)
            #expect(abs(s - prev) < 0.06)
            prev = s
            t += 1.0 / 60
        }
        // The pointer is in the picture throughout.
        for k in track where k.weight > 0.999 {
            let p = cursor(k.t)
            #expect(abs(Double(p.x) - k.focusX) <= 1920 / (2 * k.scale) + 1)
            #expect(abs(Double(p.y) - k.focusY) <= 1080 / (2 * k.scale) + 1)
        }
    }

    @Test func showBothKeepsTheWindowAndThePointerInTheFrame() {
        let short = trip(3)
        var cfg = AutoZoomConfig()
        cfg.windows = short.windows
        let track = AutoZoomTrack.build(blocks: [block(0, short.end)], cursorSamples: short.cursor,
                                        sourceSize: hd, config: cfg)
        let k = AutoZoomTrack.sample(at: 6.8, track: track)
        #expect(abs(Double(k.scale) - 1.5) < 1e-6)
        let halfW = 1920 / (2 * 1.5), halfH = 1080 / (2 * 1.5)
        // The dialog and the pointer at (1500, 900) are both inside the view.
        #expect(Double(k.focus.x) - halfW <= 600 + 1 && Double(k.focus.x) + halfW >= 1500 - 1)
        #expect(Double(k.focus.y) - halfH <= 300 + 1 && Double(k.focus.y) + halfH >= 900 - 1)
    }

    @Test func stayOnTheWindowDoesNotFollowThePointerOut() {
        let long = trip(6)
        var cfg = AutoZoomConfig()
        cfg.windows = long.windows
        let stay = AutoZoomTrack.build(
            blocks: [block(0, long.end, show: .window)],
            cursorSamples: long.cursor, sourceSize: hd, config: cfg)
        let before = AutoZoomTrack.sample(at: 4, track: stay).focus
        let during = AutoZoomTrack.sample(at: 9, track: stay).focus
        #expect(abs(during.x - before.x) < 1 && abs(during.y - before.y) < 1)
        // Following the pointer instead, it goes.
        let follow = AutoZoomTrack.build(
            blocks: [block(0, long.end, show: .pointer)],
            cursorSamples: long.cursor, sourceSize: hd, config: cfg)
        #expect(AutoZoomTrack.sample(at: 9, track: follow).focus.x > before.x + 200)
    }

    // MARK: - Auto zoom

    private var config: AutoZoomSuggestConfig {
        var c = AutoZoomSuggestConfig(rampIn: 0.475, rampOut: 0.475)
        c.viewSize = hd
        c.defaultScale = 2
        c.auto = ZoomAutoScale()
        c.show = .auto
        return c
    }

    @Test func generatedFollowBlocksAreAutoAndTypingBlocksMatchTheirWindow() {
        // A click outside the dialog first, so the run itself gets no scale.
        let activity = ZoomActivity(
            clicks: [ClickSample(t: 1, p: CGPoint(x: 1500, y: 900)),
                     ClickSample(t: 1.4, p: CGPoint(x: 1600, y: 950)),
                     ClickSample(t: 2, p: CGPoint(x: 650, y: 350))],
            typing: [TimeSpan(begin: 2.5, end: 6)])
        let blocks = AutoZoomSuggester.suggest(
            activity: activity, cursorSamples: [], span: 0...60, sourceSize: hd, cuts: [],
            config: config, windows: [WindowSpan(begin: 1.8, end: 20, rect: dialog, id: 1)])
        let follow = blocks.filter { ($0.mode ?? .follow) == .follow }
        let typing = blocks.filter { $0.mode == .manual }
        #expect(!follow.isEmpty && typing.count == 1)
        #expect(follow.allSatisfy { $0.auto == ZoomAutoScale() && $0.show == .auto && $0.scale == nil })
        #expect(typing[0].auto == nil)
        #expect(typing[0].scale == 2.3)         // what the auto pieces around it take
    }

    @Test func onlyThisBlockRespectsHowTheBlockWasSet() {
        let generated = [ZoomBlock(begin: 2, end: 6, scale: 2.5, auto: ZoomAutoScale(), show: .auto)]
        func merged(_ old: ZoomBlock) -> ZoomBlock {
            AutoZoomSuggester.merge(existing: [old], generated: generated, scope: .block(old.id))[0]
        }
        // A fixed scale the user chose stays fixed.
        let fixed = merged(ZoomBlock(begin: 0, end: 10, scale: 3))
        #expect(fixed.scale == 3 && fixed.auto == nil)
        // The block's own range wins over the generated one.
        let own = ZoomAutoScale(min: 1.2, max: 2)
        #expect(merged(ZoomBlock(begin: 0, end: 10, auto: own)).auto == own)
        // A block on the default scale takes what was generated.
        let plain = merged(ZoomBlock(begin: 0, end: 10))
        #expect(plain.scale == 2.5 && plain.auto == ZoomAutoScale() && plain.show == .auto)
        // What the block was told to show is kept, and so is its zoom kind.
        let told = merged(ZoomBlock(begin: 0, end: 10, show: .window))
        #expect(told.show == .window && told.auto == nil)
        #expect(fixed.show == .pointer)
        #expect(merged(ZoomBlock(begin: 0, end: 10, auto: own, show: .both)).show == .both)
        // "All": as generated.
        #expect(AutoZoomSuggester.merge(existing: [], generated: generated, scope: .all)[0].auto
                == ZoomAutoScale())
    }

    @Test func applyToAllCopiesTheAutoSettings() {
        let own = ZoomAutoScale(min: 1.2, max: 2)
        let a = ZoomBlock(begin: 0, end: 2, auto: own, show: .both), b = ZoomBlock(begin: 3, end: 5, scale: 2)
        let out = ZoomTimeline.applyingFollowSettings(of: a.id, toAll: [a, b])
        #expect(out.map(\.auto) == [own, own])
        #expect(out.map(\.show) == [.both, .both])
        #expect(out[1].scale == 2)
        // From a manual (typing) block: sensitivity spreads, auto settings stay.
        let typing = ZoomBlock(begin: 6, end: 8, sensitivity: 0.9, mode: .manual)
        let spread = ZoomTimeline.applyingFollowSettings(of: typing.id, toAll: [a, b, typing])
        #expect(spread.map(\.sensitivity) == [0.9, 0.9, 0.9])
        #expect(spread.map(\.auto) == [own, nil, nil])
        // A block holding a window: its (unshown) edge setting is not spread.
        var held = ZoomBlock(begin: 9, end: 11, show: .window)
        held.overflow = true
        let kept = ZoomTimeline.applyingFollowSettings(of: held.id, toAll: [b, held])
        #expect(kept[0].overflow == nil && kept[0].show == .window)
        // Onto a manual block: it gets no auto settings.
        #expect(ZoomTimeline.applyingFollowSettings(of: a.id, toAll: [a, typing])[1].auto == nil)
    }

    @Test func aFastHopIntoASmallerWindowKeepsThePointerInThePicture() {
        let wide = CGRect(x: 100, y: 100, width: 1000, height: 600)
        let small = CGRect(x: 1400, y: 600, width: 400, height: 300)
        let cursor: (Double) -> CGPoint = { t in
            let a = CGPoint(x: 600, y: 400), b = CGPoint(x: 1600, y: 750)
            let f = min(max((t - 5.8) / 0.4, 0), 1)
            return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
        var cfg = AutoZoomConfig()
        cfg.windows = [WindowSpan(begin: 0, end: 6, rect: wide, id: 1),
                       WindowSpan(begin: 6, end: 12, rect: small, id: 2)]
        let track = AutoZoomTrack.build(blocks: [block(0, 12, show: .pointer)],
                                        cursorSamples: samples(end: 12, cursor), sourceSize: hd,
                                        config: cfg)
        for k in track where k.weight > 0.999 {
            let p = cursor(k.t)
            #expect(abs(Double(p.x) - k.focusX) <= 1920 / (2 * k.scale) + 2)
            #expect(abs(Double(p.y) - k.focusY) <= 1080 / (2 * k.scale) + 2)
        }
    }

    // MARK: - What a block does (the inspector's summary)

    private func story(_ b: ZoomBlock, windows: [WindowSpan] = [], reveals: [Reveal] = [],
                       cursor: [CursorSample] = []) -> ZoomBlockStory {
        var cfg = AutoZoomConfig()
        cfg.windows = windows
        cfg.reveals = reveals
        return ZoomBlockSummary.story(of: b, in: [b], cursor: cursor, sourceSize: hd, config: cfg)
    }
    private func kinds(_ s: ZoomBlockStory) -> [ZoomPhase.Kind] { s.phases.map(\.kind) }

    @Test func theStorySaysWhatTheBlockStaysWith() {
        let long = trip(6), short = trip(3)
        func run(_ show: ZoomShow, _ t: (windows: [WindowSpan], cursor: [CursorSample], end: Double))
            -> ZoomBlockStory {
            story(block(0, t.end, show: show), windows: t.windows, cursor: t.cursor)
        }
        // Decide for me: a short trip shows both, a long one goes with the pointer.
        #expect(kinds(run(.auto, short)) == [.window, .both, .window])
        #expect(kinds(run(.auto, long)) == [.window, .pointer, .window])
        #expect(run(.auto, short).phases.map { [$0.begin, $0.end, $0.scale] }
                == [[0, 5, 2.3], [5, 8, 1.5], [8, 13, 2.3]])
        // The window: on it throughout; the middle stretch says the pointer left.
        #expect(kinds(run(.window, long)) == [.window, .holdWindow, .window])
        #expect(kinds(run(.both, long)) == [.window, .both, .window])
        #expect(kinds(run(.pointer, long)) == [.window, .pointer, .window])
        // "Window and pointer" that cannot hold both says so: with the pointer.
        let tight = story(block(0, long.end, ZoomAutoScale(min: 2, max: 3), show: .both),
                          windows: long.windows, cursor: long.cursor)
        #expect(kinds(tight) == [.window, .pointer, .window])
    }

    @Test func theStoryOfPlainAndFixedSpotBlocks() {
        let plain = story(block(2, 6, scale: 1.8, nil))
        #expect(plain.phases == [ZoomPhase(begin: 2, end: 6, kind: .pointer, scale: 1.8)])
        let spot = story(ZoomBlock(begin: 2, end: 6, scale: 2.5, mode: .manual))
        #expect(spot.phases == [ZoomPhase(begin: 2, end: 6, kind: .spot, scale: 2.5)])
        // No window data: "decide for me" goes with the pointer, and says so.
        #expect(kinds(story(block(0, 6))) == [.pointer])
    }

    @Test func theStoryListsWhatThePictureLeansToward() {
        let p = CGPoint(x: 700, y: 400)
        let reveals = [Reveal(t: 3, click: p, rect: CGRect(x: 700, y: 400, width: 200, height: 200)),
                       Reveal(t: 9, click: p, rect: CGRect(x: 700, y: 400, width: 200, height: 200))]
        let windows = [WindowSpan(begin: 0, end: 6, rect: dialog, id: 1)]
        #expect(story(block(0, 6, show: .auto), windows: windows, reveals: reveals).leans == [3])
        // "The window" leans toward nothing.
        #expect(story(block(0, 6, show: .window), windows: windows, reveals: reveals).leans.isEmpty)
        #expect(story(block(0, 6, scale: 2, nil), reveals: reveals).leans == [3])
    }

    @Test func aBlockSaysWhereItCameFrom() {
        #expect(ZoomInspector.origin(nil) == nil)          // not recorded: say nothing
        #expect(ZoomInspector.origin(ZoomMade(byHand: true)) == "Added by hand")
        #expect(ZoomInspector.leanLine([]) == nil)
        #expect(ZoomInspector.leanLine([36.1, 36.8, 3, 40, 50, 61, 70])
                == "Leans toward what a click opened at 0:03, 0:36, 0:40, 0:50 and 2 more.")
        #expect(ZoomInspector.origin(ZoomMade(clicks: 3, drags: 0, typing: true))
                == "Made by Auto zoom from 3 clicks and typing")
        #expect(ZoomInspector.origin(ZoomMade(clicks: 1, drags: 2, typing: true))
                == "Made by Auto zoom from 1 click, 2 drags and typing")
        #expect(ZoomInspector.origin(ZoomMade(clicks: 0, drags: 1, typing: false))
                == "Made by Auto zoom from 1 drag")
        #expect(ZoomInspector.phaseLine(ZoomPhase(begin: 72, end: 75.4, kind: .both, scale: 1.5))
                == "1:12 – 1:15   Window and pointer · 1.5×")

        // Auto zoom records what it saw; a block added by hand has nothing.
        let activity = ZoomActivity(
            clicks: [ClickSample(t: 5, p: CGPoint(x: 900, y: 500)),
                     ClickSample(t: 6, p: CGPoint(x: 900, y: 500))],
            drags: [TimeSpan(begin: 7, end: 7.8)], typing: [TimeSpan(begin: 20, end: 24)])
        let blocks = AutoZoomSuggester.suggest(activity: activity, cursorSamples: [], span: 0...60,
                                               sourceSize: hd, cuts: [], config: config)
        #expect(blocks.first?.made == ZoomMade(clicks: 2, drags: 1, typing: false))
        #expect(blocks.last?.made == ZoomMade(clicks: 0, drags: 0, typing: true))
        #expect(ZoomBlock(begin: 0, end: 1).made == nil)
        // It survives a save, and odd data there never fails the project.
        let saved = try? JSONEncoder().encode(blocks[0])
        #expect(saved.flatMap { try? JSONDecoder().decode(ZoomBlock.self, from: $0) }?.made
                == blocks[0].made)
        let odd = Data(#"{"id":"\#(UUID().uuidString)","begin":0,"end":1,"made":"x"}"#.utf8)
        #expect((try? JSONDecoder().decode(ZoomBlock.self, from: odd))?.made == nil)
        let partial = Data(#"{"id":"\#(UUID().uuidString)","begin":0,"end":1,"made":{"clicks":2}}"#.utf8)
        #expect((try? JSONDecoder().decode(ZoomBlock.self, from: partial))?.made
                == ZoomMade(clicks: 2))
    }

    @Test func theTimelineSymbolFollowsWhatTheBlockShows() {
        #expect(ZoomTimelineLane.icon(for: ZoomBlock(begin: 0, end: 1)) == "cursorarrow")
        #expect(ZoomTimelineLane.icon(for: block(0, 1)) == "sparkles")
        #expect(ZoomTimelineLane.icon(for: block(0, 1, show: .window)) == "macwindow")
        #expect(ZoomTimelineLane.icon(for: block(0, 1, show: .both)) == "macwindow.and.cursorarrow")
        #expect(ZoomTimelineLane.icon(for: ZoomBlock(begin: 0, end: 1, mode: .manual,
                                                     show: .window)) == "pin.fill")
    }

    // MARK: - Range slider

    @Test func theRangeSliderSnapsAndGrabsTheNearerEnd() {
        let b = 1.0...6.0
        #expect(RangeSliderMath.value(atX: 0, width: 200, bounds: b, step: 0.05) == 1)
        #expect(RangeSliderMath.value(atX: 500, width: 200, bounds: b, step: 0.05) == 6)
        #expect(abs(RangeSliderMath.value(atX: 22, width: 200, bounds: b, step: 0.05) - 1.55) < 1e-9)
        #expect(RangeSliderMath.value(atX: 10, width: 0, bounds: b, step: 0.05) == 1)
        #expect(RangeSliderMath.grabsLower(value: 1.6, lower: 1.5, upper: 3, bounds: b))
        #expect(!RangeSliderMath.grabsLower(value: 2.8, lower: 1.5, upper: 3, bounds: b))
        // Both on one spot: the press decides by its side.
        #expect(RangeSliderMath.grabsLower(value: 1.8, lower: 2, upper: 2, bounds: b))
        #expect(!RangeSliderMath.grabsLower(value: 2.4, lower: 2, upper: 2, bounds: b))
        #expect(!RangeSliderMath.grabsLower(value: 2, lower: 2, upper: 2, bounds: b))
        // Both at the top: only the lower one can move, so it is the one grabbed.
        #expect(RangeSliderMath.grabsLower(value: 6, lower: 6, upper: 6, bounds: b))
    }
}
