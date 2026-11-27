import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

@Suite struct ZoomShotPlannerTests {
    // 1920×1080 source viewed at 2×.
    private let half = CGSize(width: 480, height: 270)
    private let reach = CGRect(x: 480, y: 270, width: 960, height: 540)
    private let step = 1.0 / 60.0
    private var tuning: FollowTuning { ZoomShotPlanner.followTuning(0.5) }

    private func plan(_ cursor: (Double) -> CGPoint, end: Double, start: CGPoint? = nil,
                      reach: CGRect? = nil, breaks: [Double] = []) -> [PlannedShot] {
        ZoomShotPlanner.shots(cursor: cursor, begin: 0, end: end, start: start, half: half,
                              tuning: tuning, reach: reach ?? self.reach, breaks: breaks,
                              step: step)
    }

    private func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 2) -> Bool {
        abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol
    }

    // MARK: - Tuning

    @Test func followTuningEndpoints() {
        let lo = ZoomShotPlanner.followTuning(0), hi = ZoomShotPlanner.followTuning(1)
        #expect(abs(lo.safeFrac - 0.80) < 1e-9 && abs(lo.vPref - 0.7) < 1e-9
                && abs(lo.flickGrace - 0.50) < 1e-9)
        #expect(abs(hi.safeFrac - 0.25) < 1e-9 && abs(hi.vPref - 1.3) < 1e-9
                && abs(hi.flickGrace - 0.10) < 1e-9)
        #expect(ZoomShotPlanner.followTuning(-1) == lo)
        #expect(ZoomShotPlanner.followTuning(2) == hi)
    }

    // MARK: - Shots

    @Test func stillCursorIsOneShot() {
        let shots = plan({ _ in CGPoint(x: 960, y: 540) }, end: 5)
        #expect(shots.count == 1)
        #expect(near(shots[0].center, CGPoint(x: 960, y: 540), 0.01))
    }

    @Test func movementInsideSafeZoneIsOneShot() {
        let shots = plan({ t in CGPoint(x: 960 + 100 * sin(t * 3), y: 540 + 60 * cos(t * 2)) },
                         end: 6)
        #expect(shots.count == 1)
    }

    @Test func flickThatReturnsIsIgnored() {
        // Safe zone ±252 px (0.525·480), hard margin ±441.6. A 0.1 s excursion to
        // +350 stays inside the hard margin and returns within the 0.3 s grace.
        let shots = plan({ t in CGPoint(x: (t >= 2 && t < 2.1) ? 1310 : 960, y: 540) }, end: 5)
        #expect(shots.count == 1)
    }

    @Test func flickAcrossHardMarginExits() {
        // Snappy tuning (safe zone ±120 px, so one shot cannot cover both spots).
        // A 0.05 s excursion to +460 crosses the hard margin (0.92·480 = 441.6):
        // it counts as an exit even though it returns within the grace period.
        let snappy = ZoomShotPlanner.followTuning(1)
        let shots = ZoomShotPlanner.shots(
            cursor: { t in CGPoint(x: (t >= 2 && t < 2.05) ? 1420 : 960, y: 540) },
            begin: 0, end: 5, start: nil, half: half, tuning: snappy, reach: reach,
            breaks: [], step: step)
        #expect(shots.count >= 2)
    }

    @Test func relocationMakesOneShotAtLanding() {
        // Rest at the centre, fly 0.3 s, rest at (1500, 700).
        let cursor: (Double) -> CGPoint = { t in
            let f = min(max((t - 2) / 0.3, 0), 1)
            return CGPoint(x: 960 + 540 * f, y: 540 + 160 * f)
        }
        let shots = plan(cursor, end: 6)
        #expect(shots.count == 2)
        #expect(near(shots[1].aim, CGPoint(x: 1500, y: 700)))
        #expect(near(shots[1].center, CGPoint(x: 1440, y: 700)))   // x clamped by reach
        #expect(shots[1].tExit < shots[1].tArrive)
        #expect(!shots[1].isCut)
    }

    @Test func fastSweepChainsShots() {
        let wide = CGRect(x: 0, y: 0, width: 10_000, height: 1080)
        let shots = plan({ t in CGPoint(x: 500 + 2000 * t, y: 540) }, end: 3, reach: wide)
        #expect(shots.count >= 3)
        for s in shots.dropFirst() {
            #expect(s.tArrive - s.tExit <= ZoomShotPlanner.maxTransit + step + 1e-9)
        }
    }

    @Test func cursorParkedBeyondReachIsOneShot() {
        let p = CGPoint(x: 1900, y: 1060)
        let shots = plan({ _ in p }, end: 10)
        #expect(shots.count == 1)
        #expect(near(shots[0].center, CGPoint(x: 1440, y: 810), 0.01))
        #expect(near(shots[0].aim, p, 0.01))
    }

    @Test func breakStartsCutShot() {
        let shots = plan({ t in CGPoint(x: t < 2 ? 700 : 1300, y: 540) }, end: 5, breaks: [2])
        #expect(shots.count == 2)
        #expect(shots[1].isCut)
        #expect(abs(shots[1].tExit - 2) < 1e-9 && abs(shots[1].tArrive - 2) < 1e-9)
        #expect(near(shots[1].center, CGPoint(x: 1300, y: 540), 0.01))
    }

    @Test func startAimIsCarriedIn() {
        let shots = plan({ _ in CGPoint(x: 700, y: 400) }, end: 3,
                         start: CGPoint(x: 700, y: 400))
        #expect(shots.count == 1)
        #expect(near(shots[0].aim, CGPoint(x: 700, y: 400), 0.01))
    }

    @Test func invertedReachCollapsesToMidpoint() {
        // View wider than the content: max.x < min.x by 100.
        let inverted = CGRect(x: 1010, y: 270, width: -100, height: 540)
        let shots = plan({ t in CGPoint(x: t < 2 ? 300 : 1700, y: 540) }, end: 5,
                         reach: inverted)
        #expect(!shots.isEmpty)
        for s in shots {
            #expect(abs(s.center.x - 960) < 1e-6)
            #expect(s.center.x.isFinite && s.center.y.isFinite)
        }
    }

    @Test func planningIsLinearInSamples() {
        let patterns: [(Double) -> CGPoint] = [
            // Rest, then jump to the other side every 3 s.
            { t in CGPoint(x: Int(t / 3) % 2 == 0 ? 600 : 1400, y: 540) },
            // Parked in a corner beyond the reach.
            { _ in CGPoint(x: 1900, y: 1060) },
        ]
        for pattern in patterns {
            func calls(_ end: Double) -> Int {
                var count = 0
                _ = plan({ t in count += 1; return pattern(t) }, end: end)
                return count
            }
            let short = calls(60), long = calls(600)
            #expect(long <= 12 * short)
        }
    }

    // MARK: - Moves

    @Test func minJerkEndpointsAndMidpoint() {
        #expect(ZoomShotPlanner.minJerk(-0.5) == 0)
        #expect(abs(ZoomShotPlanner.minJerk(0) - 0.5) < 1e-12)
        #expect(ZoomShotPlanner.minJerk(0.5) == 1)
        #expect(ZoomShotPlanner.minJerk(-9) == 0)
        #expect(ZoomShotPlanner.minJerk(9) == 1)
        let h = 1e-3
        #expect(abs(ZoomShotPlanner.minJerk(-0.5 + h) / h) < 1e-3)
        #expect(abs((1 - ZoomShotPlanner.minJerk(0.5 - h)) / h) < 1e-3)
    }

    @Test func durationGrowsThenSaturates() {
        #expect(abs(ZoomShotPlanner.duration(dNorm: 0.1, vPref: 1.0) - 0.35) < 1e-9)
        #expect(abs(ZoomShotPlanner.duration(dNorm: 0.7, vPref: 1.0) - 0.7) < 1e-9)
        #expect(abs(ZoomShotPlanner.duration(dNorm: 5, vPref: 1.0) - 1.4) < 1e-9)
    }

    @Test func dipOnlyOnDurationCappedMoves() {
        #expect(ZoomShotPlanner.dipRatio(hold: 2, dNorm: 0.5, d: 0.5) == 1)
        #expect(ZoomShotPlanner.dipRatio(hold: 2, dNorm: 3, d: 0.7) == 1)     // shortened
        #expect(ZoomShotPlanner.dipRatio(hold: 2, dNorm: 1.5, d: 1.4) == 1)   // under vMax
        #expect(abs(ZoomShotPlanner.dipRatio(hold: 2, dNorm: 3, d: 1.4) - 0.6222) < 1e-3)
        #expect(abs(ZoomShotPlanner.dipRatio(hold: 2, dNorm: 20, d: 1.4) - 0.55) < 1e-9)
        #expect(ZoomShotPlanner.dipRatio(hold: 1.05, dNorm: 20, d: 1.4) == 1)
    }

    @Test func dipDepthGrowsWithDistance() {
        #expect(ZoomShotPlanner.dipRatio(hold: 2, dNorm: 3, d: 1.4)
                > ZoomShotPlanner.dipRatio(hold: 2, dNorm: 4, d: 1.4))
    }

    @Test func uncappedMovesNeverExceedVMax() {
        for vPref in stride(from: 0.7, through: 1.3, by: 0.1) {
            for dn in stride(from: 0.1, through: 5.0, by: 0.1) {
                let d = ZoomShotPlanner.duration(dNorm: dn, vPref: vPref)
                if d < ZoomShotPlanner.dMax - 1e-9 {
                    #expect(1.875 * dn / d <= ZoomShotPlanner.vMax + 1e-9)
                }
            }
        }
    }

    @Test func focusBeforeDuringAfterMove() {
        let o = CGPoint(x: 100, y: 50)
        let m = [ZoomMove(t: 1, d: 1, dx: 100, dy: 0)]
        #expect(abs(ZoomShotPlanner.focus(at: 0.4, origin: o, moves: m).x - 100) < 1e-9)
        #expect(abs(ZoomShotPlanner.focus(at: 1.0, origin: o, moves: m).x - 150) < 1e-9)
        #expect(abs(ZoomShotPlanner.focus(at: 1.6, origin: o, moves: m).x - 200) < 1e-9)
        #expect(abs(ZoomShotPlanner.focus(at: 1.0, origin: o, moves: m).y - 50) < 1e-9)
    }

    @Test func overlappingMovesAdd() {
        let m = [ZoomMove(t: 1, d: 1, dx: 100, dy: 0), ZoomMove(t: 1.2, d: 1, dx: 100, dy: 0)]
        #expect(abs(ZoomShotPlanner.focus(at: 3, origin: .zero, moves: m).x - 200) < 1e-9)
        var prev = -1.0
        for i in 0...120 {
            let x = Double(ZoomShotPlanner.focus(at: Double(i) / 60, origin: .zero, moves: m).x)
            #expect(x >= prev - 1e-9)
            prev = x
        }
    }

    @Test func zeroDurationMoveIsAStep() {
        let m = [ZoomMove(t: 2, d: 0, dx: 300, dy: -40)]
        #expect(ZoomShotPlanner.focus(at: 1.999, origin: .zero, moves: m).x == 0)
        #expect(ZoomShotPlanner.focus(at: 2, origin: .zero, moves: m).x == 300)
        #expect(ZoomShotPlanner.focus(at: 2, origin: .zero, moves: m).y == -40)
    }

    @Test func peakSpeedMatchesMinJerkBound() {
        let m = [ZoomMove(t: 1, d: 0.8, dx: 500, dy: 0)]
        var peak = 0.0
        var prev = Double(ZoomShotPlanner.focus(at: 0, origin: .zero, moves: m).x)
        for i in 1...120 {
            let x = Double(ZoomShotPlanner.focus(at: Double(i) * step, origin: .zero, moves: m).x)
            peak = max(peak, abs(x - prev) / step)
            prev = x
        }
        #expect(peak <= 1.875 * 500 / 0.8 * 1.01)
        #expect(peak >= 1.875 * 500 / 0.8 * 0.95)
    }

    @Test func dipFactorIsOneOutsideMoves() {
        let m = [ZoomMove(t: 2, d: 1.4, dx: 900, dy: 0, dipRatio: 0.6)]
        #expect(ZoomShotPlanner.dipFactor(at: 0.5, moves: m) == 1)
        #expect(ZoomShotPlanner.dipFactor(at: 3.5, moves: m) == 1)
        #expect(abs(ZoomShotPlanner.dipFactor(at: 2, moves: m) - 0.6) < 1e-9)
        #expect(ZoomShotPlanner.dipFactor(at: 2, moves: []) == 1)
    }

    // MARK: - Move timing

    @Test func moveTimeDefaultsToMidpoint() {
        // Short hop; the cursor is already in flight between exit and arrival.
        let cursor: (Double) -> CGPoint = { t in
            let f = min(max((t - 1.8) / 0.4, 0), 1)
            return CGPoint(x: 960 + 300 * f, y: 540)
        }
        let t = ZoomShotPlanner.moveTime(cursor: cursor, from: CGPoint(x: 960, y: 540),
                                         delta: CGVector(dx: 300, dy: 0), d: 0.35,
                                         tExit: 2.0, tArrive: 2.2, half: half, step: step)
        #expect(abs(t - 2.1) < 1e-9)
    }

    @Test func moveTimeDelaysForRestingCursor() {
        // 4× view (half 240×135): the cursor rests until it leaves at t = 2, then
        // hops 1380 px. Leaving D/2 early would push it out of frame.
        let h = CGSize(width: 240, height: 135)
        let from = CGPoint(x: 300, y: 540)
        let cursor: (Double) -> CGPoint = { t in
            let f = min(max((t - 1.95) / 0.25, 0), 1)
            return CGPoint(x: 300 + 1400 * f, y: 540)
        }
        let d = 1.4, tExit = 2.0, tArrive = 2.2
        let t = ZoomShotPlanner.moveTime(cursor: cursor, from: from,
                                         delta: CGVector(dx: 1380, dy: 0), d: d,
                                         tExit: tExit, tArrive: tArrive, half: h, step: step)
        #expect(t > (tExit + tArrive) / 2)
        var tau = 0.0
        while tau <= tExit {
            let view = Double(from.x) + 1380 * ZoomShotPlanner.minJerk((tau - t) / d)
            #expect(abs(Double(cursor(tau).x) - view) <= 0.92 * 240 + 1)
            tau += step
        }
    }

    @Test func moveTimeNeverLaterThanExitPlusHalf() {
        // A cursor that is never in frame cannot be satisfied: fall back to
        // "start at the exit".
        let t = ZoomShotPlanner.moveTime(cursor: { _ in CGPoint(x: 5000, y: 5000) },
                                         from: .zero, delta: CGVector(dx: 800, dy: 0),
                                         d: 1.0, tExit: 2.0, tArrive: 2.3, half: half,
                                         step: step)
        #expect(t <= 2.5 + step)
        #expect(t >= 2.15)
    }
}
