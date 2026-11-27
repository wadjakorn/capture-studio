# Smooth Auto Zoom/Pan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the causal cursor-follow inside zoom blocks with an offline shot planner (hold → eased move → hold, zoom dip on long hops), and add an "Auto zoom" button that generates zoom blocks from recorded clicks, drags, typing and scrolls.

**Architecture:** Two new pure units. `ZoomShotPlanner` turns a cursor path into shots and closed-form minimum-jerk moves; `AutoZoomTrack.build` keeps its run/envelope logic and public output (`[ZoomKeyframe]`) but gets its focus and dip from the planner. `AutoZoomSuggester` turns recorded activity into ordinary `ZoomBlock`s. `StudioModel` only wires inputs (view size, content rect, cut times, activity) and the new action; the compositor and all on-disk schemas are untouched.

**Tech Stack:** Swift 6, SwiftUI, CoreGraphics, swift-testing 0.12.0. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-27-smooth-auto-zoom-pan-design.md` — read it first; this plan cites its sections by name.

## Global Constraints

- `ZoomKeyframe` fields and `AutoZoomTrack.sample(at:track:)` do not change. `CameraCompositor.swift` is not edited.
- No change to `ZoomBlock`, `EditState`, `events.jsonl`, `meta.json` schemas.
- Planner and suggester files import only `Foundation` and `CoreGraphics`.
- No `#Preview`, no dependency bumps. Must pass `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test`.
- `Tests/CaptureStudioTests/ZoomRampContinuityTests.swift` and `RecenterTargetTests.swift` pass unmodified.
- **Do not commit.** Project rule: no commit or push without explicit user confirmation. Each task ends by leaving its changes in the working tree with `swift build` and the task's tests green; the user is asked once, at the end, whether to commit.
- Constants (spec "Sensitivity mapping"): `dMin` 0.35 s, `dMax` 1.4 s, `vMax` 2.5, `vRest` 0.3, `maxTransit` 0.8 s, hard margin 0.92; dip floor 1.1; `safeFrac` 0.80→0.25, `vPref` 0.7→1.3, `flickGrace` 0.50→0.10 (linear in sensitivity 0→1).
- Suggester constants (spec "Rules"): `postHold` 1.2 s, `minWide` 1.0 s, pre-roll pad 0.2 s, scroll split ≥ 0.5 s, scroll gap 0.3 s, key gap 1.0 s, min keys 3, typing block ≥ 1.0 s, typing click window 10 s, min hold 1.0 s.

## Review Focus

1. **No cursor samples inside a follow block** (camera-main bundle, or events ended early): camera centres on the content rect, no crash, no NaN. → Task 3 test `followBlockWithoutSamplesCentresOnContent`.
2. **View larger than the content on an axis** (block scale 1, a tight crop, a letterboxed fit): reach inverts; the centre falls back to the midpoint on that axis and no move or dip is planned along it. → Task 1 test `invertedReachCollapsesToMidpoint`; Task 3 test `letterboxAxisNeverPans`.
3. **Long recordings**: the track is rebuilt on every slider tick, so planning must stay linear in samples, including a cursor parked in a corner beyond the reach. → Task 1 tests `planningIsLinearInSamples`, `cursorParkedBeyondReachIsOneShot`.
4. **Recording without key events** (Input Monitoring not granted) or with no clicks at all: suggester returns `[]`, and the model leaves existing blocks untouched. → Task 5 test `noKeysStillClustersClicks`; Task 6 test `nothingFoundLeavesBlocksUntouched`.
5. **Stale selection**: "Only this block" with an id that no longer exists is a no-op, not a replace-all. → Task 6 test `blockScopeWithUnknownIDIsNoOp`.

---

## File map

| File | Responsibility |
|---|---|
| `Sources/CaptureStudio/Studio/ZoomShotPlanner.swift` (new) | Shots from a cursor path; move timing; minimum-jerk path; dip law. Pure. |
| `Sources/CaptureStudio/Studio/AutoZoom.swift` | Run/envelope logic; assembles shots and seams into moves; emits keyframes; `viewSize` helper. |
| `Sources/CaptureStudio/Studio/ZoomActivity.swift` (new) | Activity types + extraction from `[EventLine]`. Pure. |
| `Sources/CaptureStudio/Studio/AutoZoomSuggester.swift` (new) | Activity → `[ZoomBlock]`; merge into existing blocks. Pure. |
| `Sources/CaptureStudio/Studio/StudioModel.swift` | Pass view size, content rect and cut times; load activity; `generateAutoZoom(scope:)`. |
| `Sources/CaptureStudio/Studio/Inspector/ZoomInspector.swift` | "Auto zoom" button, scope dialog, slider help text. |
| `Tests/CaptureStudioTests/ZoomShotPlannerTests.swift` (new) | Tasks 1–2. |
| `Tests/CaptureStudioTests/AutoZoomTrackTests.swift` | Rewritten in Task 3. |
| `Tests/CaptureStudioTests/ZoomActivityTests.swift`, `AutoZoomSuggesterTests.swift` (new) | Tasks 4–6. |

---

### Task 1: Shots from a cursor path

**Files:**
- Create: `Sources/CaptureStudio/Studio/ZoomShotPlanner.swift`
- Test: `Tests/CaptureStudioTests/ZoomShotPlannerTests.swift`

**Interfaces — Produces:**

```swift
struct FollowTuning: Equatable { var safeFrac: Double; var vPref: Double; var flickGrace: Double }

struct PlannedShot: Equatable {
    var aim: CGPoint      // unclamped centre; all safe-zone / hard-margin tests use this; carried between blocks
    var center: CGPoint   // aim clamped into `reach`; what the camera shows
    var tExit: Double     // when the cursor left the previous shot (== tArrive for the first shot and for cuts)
    var tArrive: Double   // when this shot's framing starts being measured
    var isCut: Bool       // entered at a discontinuity
}

enum ZoomShotPlanner {
    static let hardMargin = 0.92, vRest = 0.3, maxTransit = 0.8
    static func followTuning(_ sensitivity: Double) -> FollowTuning   // clamps to 0…1, linear per Global Constraints

    /// `cursor` returns the pointer position (source px) at a time; the caller clamps it and makes it
    /// piecewise across breaks. `half` is the view half-extent at the block's held scale. `start` is the
    /// AIM carried in from the previous follow block (nil = settle at `begin`). `reach` is the allowed
    /// range for `center`; pass min/max per axis — an axis whose max < min collapses to its midpoint.
    static func clamp(_ p: CGPoint, toReach reach: CGRect) -> CGPoint
    static func shots(cursor: (Double) -> CGPoint, begin: Double, end: Double,
                      start: CGPoint?, half: CGSize, tuning: FollowTuning,
                      reach: CGRect, breaks: [Double], step: Double) -> [PlannedShot]
}
```

**Algorithm (spec "Step 1 — Shots"), pinned where the spec leaves a choice:**

- `inSafe(p, aim)`: `|p.x − aim.x| ≤ half.width·safeFrac + 0.5` and the same in y (the 0.5 px tolerance stops a cursor sitting exactly on the settle box edge from re-exiting). `inHard` uses `hardMargin` instead of `safeFrac`.
- `reach` is passed as a `CGRect` built from explicit min/max (`CGRect(x: minX, y: minY, width: maxX − minX, height: maxY − minY)`, negative sizes allowed and never standardized); read it back with `origin` and `origin + size`, not `minX`/`maxX`.
- `settle(t0, limit)`: grow the bounding box of `cursor(t)` for `t = t0, t0+step, …` while `t < limit` and the box is at most `2·half·safeFrac` on both axes; `aim` = centre of the last fitting box.
- First shot: `aim = start ?? settle(begin)`, `tExit = tArrive = begin`.
- Scan forward from the shot's `tArrive`. At the first `t` with `!inSafe`: it is an exit if, within `[t, t+flickGrace]`, the cursor is ever `!inHard` or never returns `inSafe`; otherwise resume scanning after the return.
- On exit: `tExit = t`; `tArrive` = first `t' ≥ tExit` where the cursor's step-to-step speed, measured as `hypot(dx/(2·half.width), dy/(2·half.height))/step`, is below `vRest`, else `tExit + maxTransit`; both capped at the segment limit. New `aim = settle(tArrive, limit)`. Always adopt the new aim and resume scanning at `tArrive + step`; append a `PlannedShot` only when its `center` differs from the current one (otherwise update the current shot's `aim` in place).
- Segment limit = `end` or the next value in `breaks` inside `(begin, end)`. At a break `τ`: start a shot with `tExit = tArrive = τ`, `aim = settle(τ)`, `isCut = true`.
- Every scan index only moves forward (a failed flick check resumes after the excursion, never rewinds), so the pass is linear.

- [ ] **Step 1: Write failing tests** in `ZoomShotPlannerTests.swift`. Shared fixture: `half = (480, 270)` (1920×1080 at 2×), `reach = CGRect(x: 480, y: 270, width: 960, height: 540)`, `step = 1/60`, `tuning = followTuning(0.5)`.

```swift
@Test func followTuningEndpoints()            // s=0 → (0.80, 0.7, 0.50); s=1 → (0.25, 1.3, 0.10); s=-1 and s=2 clamp
@Test func stillCursorIsOneShot()             // constant cursor → shots.count == 1, center == cursor
@Test func movementInsideSafeZoneIsOneShot()  // ±100 px wobble around a point → count == 1
@Test func flickThatReturnsIsIgnored()        // leaves safe zone for 0.1 s (stays inside hard margin), returns → count == 1
@Test func flickAcrossHardMarginExits()       // same 0.1 s excursion but past 0.92·half → count == 2
@Test func relocationMakesOneShotAtLanding()  // 960,540 → linear 0.3 s flight → rests at 1500,700:
                                              //   count == 2; shots[1].center within 2 px of (1440, 700) (x clamped by reach);
                                              //   shots[1].aim within 2 px of (1500, 700); tExit < tArrive
@Test func fastSweepChainsShots()             // 2000 px/s sweep for 3 s, reach (0,0,10000,1080) → count ≥ 3; every tArrive − tExit ≤ maxTransit + step
@Test func cursorParkedBeyondReachIsOneShot() // cursor resting at (1900,1060) for 10 s → count == 1, center == (1440,810), aim ≈ cursor
@Test func breakStartsCutShot()               // cursor teleports at t=2, breaks=[2] → a shot with isCut, tExit == tArrive == 2
@Test func startAimIsCarriedIn()              // start: (700,400), cursor resting there → shots[0].aim == (700,400)
@Test func invertedReachCollapsesToMidpoint() // reach width −100 → every center.x == reach.midX, all values finite
@Test func planningIsLinearInSamples()        // count `cursor` closure calls for 600 s vs 60 s, for two patterns
                                              //   (rest/jump every 3 s; parked beyond reach): calls(600) ≤ 12 · calls(60)
```

- [ ] **Step 2: Run** `swift test --filter ZoomShotPlannerTests` — expected: build fails, `ZoomShotPlanner` undefined.
- [ ] **Step 3: Implement** `FollowTuning`, `PlannedShot`, `ZoomShotPlanner.followTuning`, `ZoomShotPlanner.shots` as specified above.
- [ ] **Step 4: Run** `swift test --filter ZoomShotPlannerTests` — expected: all pass.

---

### Task 2: Moves, path and dip law

**Files:**
- Modify: `Sources/CaptureStudio/Studio/ZoomShotPlanner.swift`
- Test: `Tests/CaptureStudioTests/ZoomShotPlannerTests.swift`

**Interfaces — Produces:**

```swift
struct ZoomMove: Equatable {
    var t: Double          // centre time
    var d: Double          // duration; 0 = instantaneous step at t
    var dx: Double, dy: Double
    var dipRatio: Double   // dipScale / sHold, in (0, 1]; 1 = no dip
}

extension ZoomShotPlanner {
    static let dMin = 0.35, dMax = 1.4, vMax = 2.5, dipFloor = 1.1
    static func minJerk(_ u: Double) -> Double                 // S(u) per spec; u ≤ −½ → 0, u ≥ ½ → 1
    static func bump(_ u: Double) -> Double                    // sin²(π(u+½)) for |u| < ½, else 0
    static func dNorm(dx: Double, dy: Double, half: CGSize) -> Double   // hypot(dx/(2·half.width), dy/(2·half.height))
    static func duration(dNorm: Double, vPref: Double) -> Double        // clamp(dNorm/vPref, dMin, dMax)
    static func dipRatio(hold: Double, dNorm: Double, d: Double) -> Double
        // 1 unless d ≥ dMax − 1e-9 (only a duration-capped move dips);
        // else clamp(vMax·d/(1.875·dNorm), min(1, dipFloor/hold), 1)
    /// Centre time for a follow move. Starts at (tExit + tArrive)/2 and is delayed in `step` increments,
    /// up to tExit + d/2, until at every step time τ in [t − d/2, tExit] the cursor is inside the hard
    /// margin of the view centred at `from + delta·minJerk((τ − t)/d)`.
    static func moveTime(cursor: (Double) -> CGPoint, from: CGPoint, delta: CGVector, d: Double,
                         tExit: Double, tArrive: Double, half: CGSize, step: Double) -> Double
    static func focus(at t: Double, origin: CGPoint, moves: [ZoomMove]) -> CGPoint
        // origin + Σ (dx,dy)·progress, progress = d > 0 ? minJerk((t−move.t)/d) : (t ≥ move.t ? 1 : 0)
    static func dipFactor(at t: Double, moves: [ZoomMove]) -> Double
        // min over moves with d > 0 of 1 − (1 − dipRatio)·bump((t−move.t)/d); 1 when none
}
```

- [ ] **Step 1: Write failing tests**

```swift
@Test func minJerkEndpointsAndMidpoint()   // S(-0.5)=0, S(0)=0.5, S(0.5)=1, S(-9)=0, S(9)=1; numeric slope at ±0.5 < 1e-3
@Test func durationGrowsThenSaturates()    // duration(0.1, 1.0)=0.35; duration(0.7, 1.0)=0.7; duration(5, 1.0)=1.4
@Test func dipOnlyOnDurationCappedMoves()  // dipRatio(hold: 2, dNorm: 0.5, d: 0.5) == 1
                                           // dipRatio(hold: 2, dNorm: 3, d: 0.7) == 1      (shortened move: no dip)
                                           // dipRatio(hold: 2, dNorm: 1.5, d: 1.4) == 1    (capped but under vMax)
                                           // dipRatio(hold: 2, dNorm: 3, d: 1.4) ≈ 0.6222 (±1e-3)
                                           // dipRatio(hold: 2, dNorm: 20, d: 1.4) == 0.55  (floor 1.1/hold)
                                           // dipRatio(hold: 1.05, dNorm: 20, d: 1.4) == 1
@Test func uncappedMovesNeverExceedVMax()  // for vPref in [0.7, 1.3], dNorm in 0.1…5: if duration < dMax then 1.875·dNorm/duration ≤ vMax
@Test func moveTimeDefaultsToMidpoint()    // cursor already in flight between tExit and tArrive, short hop → (tExit + tArrive)/2
@Test func moveTimeDelaysForRestingCursor()
    // cursor rests at `from` until tExit=2, half (240,135), delta dx=1380, d=1.4:
    // returned t > (tExit+tArrive)/2, and at every step τ ≤ 2: |cursor.x − (from.x + 1380·minJerk((τ−t)/1.4))| ≤ 0.92·240
@Test func moveTimeNeverLaterThanExitPlusHalf()   // result ≤ tExit + d/2 + step
@Test func dipDepthGrowsWithDistance()     // dipRatio(2, 3, 1.4) > dipRatio(2, 4, 1.4)
@Test func focusBeforeDuringAfterMove()    // one move t=1, d=1, dx=100: focus(0.4).x=origin, focus(1).x=origin+50, focus(1.6).x=origin+100
@Test func overlappingMovesAdd()           // two moves dx=100 at t=1 and t=1.2, d=1 → focus(3).x = origin+200; monotonic in between
@Test func zeroDurationMoveIsAStep()       // d=0, t=2: focus(1.999).x=origin, focus(2).x=origin+dx
@Test func peakSpeedMatchesMinJerkBound()  // max |Δfocus|/step over a single move ≤ 1.875·|dx|/d · 1.01
@Test func dipFactorIsOneOutsideMoves()    // and equals dipRatio at move.t
```

- [ ] **Step 2: Run** `swift test --filter ZoomShotPlannerTests` — expected: new tests fail to compile.
- [ ] **Step 3: Implement** the extension above.
- [ ] **Step 4: Run** `swift test --filter ZoomShotPlannerTests` — expected: all pass.

---

### Task 3: Planner inside `AutoZoomTrack`

**Files:**
- Modify: `Sources/CaptureStudio/Studio/AutoZoom.swift`
- Modify: `Tests/CaptureStudioTests/AutoZoomTrackTests.swift` (rewrite the follow-model tests; keep scale/weight/overflow tests)

**Interfaces:**
- Consumes: Task 1 `shots`, `followTuning`, `PlannedShot`; Task 2 `ZoomMove`, `duration`, `dNorm`, `dipRatio`, `focus`, `dipFactor`.
- Produces:

```swift
struct AutoZoomConfig {
    var defaultScale: Double = 2.0
    var defaultSensitivity: Double = 0.5
    var step: Double = 1.0 / 60.0
    var viewSize: CGSize? = nil             // source px visible at scale 1; nil = full source
    var contentRect: CGRect? = nil          // source rect the picture can show; nil = full source
    var discontinuities: [Double] = []      // picture cuts on the track's timeline
}
extension AutoZoomTrack {
    /// Source extent visible in `region` at scale 1 when `sourceRect` is drawn into canvas rect `placedAt`:
    /// region.size · sourceRect.size / placedAt.size, per axis.
    static func viewSize(sourceRect: CGRect, placedAt: CGRect, region: CGRect) -> CGSize
}
```

`build(blocks:cursorSamples:sourceSize:config:)` keeps its signature. Removed: `tuning(_:)`, `restRadiusFrac`, `smoothDamp`. Unchanged: run grouping, `envelope`, `blendedTarget`, `rampFor`, `sample`, `manualTarget`.

**Run assembly (replaces the body of the per-step loop's focus logic in `appendRun`):**

1. `content = config.contentRect ?? full source`, `view = config.viewSize ?? full source size`. Cursor closure for a block = `cursorPoint(at:)` clamped to `content` (contained) or the full source (overflow), falling back to `content`'s centre when there are no samples. It is piecewise across discontinuities: when a discontinuity `τ` lies between the two bracketing samples, return the earlier sample for `t < τ` and the later one for `t ≥ τ`.
2. Per block: `sB = max(1, scale ?? defaultScale)`, `half = view / (2·sB)`, `reach` = `content` inset by `half` per axis (contained; min/max passed unstandardized so the planner's midpoint rule handles an inverted axis) or the full source (overflow).
3. Walk the run's blocks producing an ordered list of **centres** with the move that reaches each one. The path origin is the first centre; every later centre contributes a move whose delta is `centre − previous centre`. No centre may change without a move.
   - **Follow block**: `shots(...)` with `start` = the previous block's last `aim` if the previous block was follow, else `nil`. Each shot after the first: `d = duration(dNorm, vPref)`, `t = moveTime(...)`; a shot with `isCut`: `d = 0`, `t = tExit`.
   - **Follow → follow** boundary `b`: if the new block's first `center` differs from the previous centre (different reach), a move with `t = b`, `d = duration(...)`.
   - **Entering manual** (follow → manual at `b`): move to the manual target (clamped to the manual block's reach), `t = b + d/2`.
   - **Leaving manual** (manual → follow at `b`): move to the follow block's first shot centre, `t = b − d/2`.
   - If a manual block's entering and leaving moves together exceed its span, scale both `d` by `span / (dIn + dOut)` and recompute their `t`.
   - **Manual → manual**: `t = b`, `d = min(duration, prevSpan, nextSpan)`.
   - Seam moves use the manual block's sensitivity and `half` for `vPref` / `dNorm`.
   - A manual block with no stored target takes the incoming centre clamped to its own reach; if the clamp moves it, that is an entering move like any other. A run that opens with such a block uses the cursor at the run start.
   - Discontinuity `τ`: any move with `d > 0` whose interval `[t − d/2, t + d/2]` contains `τ` is shortened to `d = 2·|τ − t|`; if that is below `dMin`, set `d = 0`, `t = τ`.
   - Set each move's `dipRatio = dipRatio(hold: sB, dNorm:, d:)` after all `d` adjustments.
4. Emit keyframes at `config.step` exactly as today, with:
   - `focus` = path at `t`, clamped to the full source. Evaluate it incrementally: moves are sorted by start time; keep a running base offset of finished moves and evaluate only moves still in progress, so the pass is linear in keyframes (do not sum every move at every keyframe).
   - `scale = max(1, (1 + (target − 1)·env) · dipFactor)` with `dipFactor` from the in-progress moves.
   - `weight`, `overflow`, and the final scale-1 end keyframe unchanged.

- [ ] **Step 1: Rewrite the tests.** Delete tests that reference `tuning`, dwell or deadzone (`tuningMapsSensitivityToFollowKnobs`, `focusFreezesWhileCursorStill`, `transientFlickDoesNotPanAtLowSensitivity`, `restingAtNewSpotPansAfterDelay`, `highSensitivityFollowsWithoutWaiting`, `passingThroughWithoutRestingDoesNotPan`). Keep the rest. Add (source 1920×1080, default config unless stated):

```swift
@Test func focusConstantWhileCursorInsideSafeZone()
@Test func relocationMovesOnceAndStartsBeforeExit()
    // cursor rests at (600,400) until t=2, flies 0.2 s, rests at (1300,700); block 0…6, scale 2
    // focus at t=1.0 == focus at t=1.5; focus at t=4 within 3 px of the landing shot centre;
    // focus has already changed at t = 2.0 (the exit instant); focus identical at t=4 and t=5
@Test func cursorInsideHardMarginWhileHolding()
    // property over 5 seeded pseudo-random rest/jump paths: at every keyframe where weight == 1 and
    // focus equals the next keyframe's focus (holding), |cursor − focus| ≤ 0.92·half per axis
    // (skip an axis on which focus sits at the reach limit)
@Test func restingCursorStaysInFrameUntilItLeaves()
    // scale 4: cursor rests at (300,540) until t=3, flies 0.25 s to (1700,540). For every keyframe with t ≤ 3:
    // |cursor.x − focus.x| ≤ 0.92·240
@Test func longHopDipsScaleAndRecovers()
    // same path, scale 4 (travel 1380 px = 2.875 frame-widths): min scale during the move < 3.0 and ≥ 1.1;
    // scale back to 4 ±0.02 by t = 5.5
@Test func shortHopDoesNotDip()               // 300 px hop at scale 2 → scale stays 2 ±0.01 mid-block
@Test func fullWidthHopAtTwoTimesDoesNotDip() // (200,540) → (1800,540) at scale 2 → scale stays 2 ±0.01
@Test func containedCentreStaysInReach()      // cursor in a corner → focus within [half, source − half]
@Test func offsetContentRectBoundsFocus()     // contentRect (400,0,1120,1080), viewSize (1120,1080) → focus.x ∈ [400+280, 1520−280]
@Test func framingWindowCanPanAcrossWholeContent()
    // viewSize (960,540) (a half-size window), contentRect nil, scale 2 → half (240,135);
    // cursor resting at (1800,1000) → focus within 2 px of (1680, 945)
@Test func letterboxAxisNeverPans()
    // viewSize (1920, 3413), scale 2 → half.height 853 > 540: cursor moving top↔bottom every 2 s →
    // focus.y == 540 at every keyframe and scale never dips
@Test func cursorOutsideContentRectDoesNotPullPastEdge()
@Test func followBlockWithoutSamplesCentresOnContent()   // Review Focus 1: finite values, focus == content centre
@Test func noDriftAcrossFollowBlocksOfDifferentScale()
    // follow 0…4 scale 3 | follow 4…8 scale 2, cursor resting at (1700,540) throughout:
    // focus.x at t=2 == 1600; focus.x at t=7 == 1440 (each block's reach limit), within 1 px
@Test func manualWithoutTargetHoldsIncomingCentre()   // follow | manual(nil target) | follow, cursor still → focus identical at all times
@Test func manualSeamMovesStayInsideManualBlock()
    // follow 0…3 | manual 3…6 (target 0.6,0.6 → (1152,648)) | follow 6…9, cursor resting at (600,400):
    // focus at t=2.99 == focus at t=1; focus at t=4.5 == (1152,648); focus at t=6.01 == focus at t=8 == focus at t=1
@Test func shortManualBlockStillReachesTarget()   // manual block 0.3 s between follows → focus hits target at its midpoint ±2 px
@Test func discontinuityStepsFocusInstantly()
    // cursor rests at (600,400), teleports to (1300,700) at t=2, config.discontinuities=[2], samples at
    // 60 Hz offset by +0.007 s (not step-aligned) → |focus(2+step) − focus(2−step)| > 200 px;
    // focus constant over [1.5, 2−step] and over [2+step, 3]; scale == 2 ±0.001 over [1.5, 3]
@Test func trackContinuousAcrossBlocksInRun()     // adjacent keyframes differ < 40 px with no discontinuities
@Test func viewSizeHelper()
    // sourceRect (0,0,1920,1080) placedAt (0,0,1920,1080), region (480,0,960,1080) → (960,1080)
    // sourceRect (200,100,1000,800) placedAt (0,0,500,400), region (0,0,250,400) → (500,800)
    // letterbox: sourceRect (0,0,1920,1080) placedAt (0,656,1080,607.5), region (0,0,1080,1920) → (1920, ≈3413)
```

- [ ] **Step 2: Run** `swift test --filter AutoZoomTrackTests` — expected: compile errors / failures on the new tests.
- [ ] **Step 3: Implement** the config fields, `viewSize` helper and run assembly; delete `tuning`, `restRadiusFrac`, `smoothDamp`.
- [ ] **Step 4: Fix other callers.** `grep -rn "tuning(\|restRadiusFrac" Sources Tests` must return nothing.
- [ ] **Step 5: Run** `swift test` — expected: all pass (covers `ZoomRampContinuityTests` and `RecenterTargetTests`).

---

### Task 4: Wire view, content rect and cuts in `StudioModel`

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (`autoZoomConfig` ~line 203; `seedManualFocus` ~line 1526; `withCollapsedTimeline` ~line 2966; the layout section of `buildCompositorComposition` ~line 2566–2596)
- Modify: `Sources/CaptureStudio/Studio/Inspector/ZoomInspector.swift` (sensitivity caption)
- Test: `Tests/CaptureStudioTests/AutoZoomTrackTests.swift`

**Interfaces:**
- Consumes: `AutoZoomConfig.viewSize`, `.contentRect`, `.discontinuities`, `AutoZoomTrack.viewSize(sourceRect:placedAt:region:)`.
- Produces: `StudioModel.autoZoomConfig` filled with both; `static func collapsedCutTimes(_ cuts: [Range<Double>]) -> [Double]` on `AutoZoomTrack` (each cut's `TimelineCut.map(lowerBound)`, deduplicated, excluding 0).

- [ ] **Step 1: Write failing test** `collapsedCutTimesMapEachCutStart`: cuts `[2..<3, 5..<7]` → `[2, 4]`; cut `[0..<1]` → `[]`.
- [ ] **Step 2: Run** `swift test --filter AutoZoomTrackTests` — expected: fails to compile.
- [ ] **Step 3: Implement** `collapsedCutTimes`.
- [ ] **Step 4: View and content.** In `autoZoomConfig`, from the same values the layout uses: cover/crop mode → `sourceRect = cropRectInSource ?? full source`, `placedAt` = full canvas; fit mode → `sourceRect` = full source, `placedAt` = the `CropMath.fitPlacement` rect; `region` = the framing-window rect when `frameEnabled`, else the full canvas. Set `contentRect = sourceRect` and `viewSize = AutoZoomTrack.viewSize(sourceRect:placedAt:region:)`. Factor the rect computations out of `buildCompositorComposition` so both call sites share one source of truth. Before writing it, confirm against `CameraCompositor.sourceToCanvas` / `screenCanvasImage` that the crop rect maps onto the full canvas in cover mode; if it does not, use the mapping those functions implement. The check that this agrees with the compositor is `RecenterTargetTests.containedToASmallFramingWindowStaysCovered`: the planner's reach must equal the range of focus values that test shows the clamp leaves un-shifted.
- [ ] **Step 5: Discontinuities.** Add a private stored `collapsedCutTimes: [Double] = []` that `withCollapsedTimeline` sets from its `cuts` (snapshot/restore with the other fields) and `autoZoomConfig` reads.
- [ ] **Step 6: `seedManualFocus`.** When `previewCuts` is non-empty and `previewComposition` exists, build the track inside `withCollapsedTimeline(cuts: previewCuts, cutComposition: previewComposition)` and sample it at `TimelineCut.map(t, cuts: previewCuts)`; otherwise as today. The stored target stays normalized.
- [ ] **Step 7: Caption.** Replace the sensitivity help text in `ZoomInspector` with: `"How readily the frame moves to follow the cursor — low = holds longer and glides, high = follows closely."`
- [ ] **Step 8: Run** `swift build && swift test` — expected: all pass.
- [ ] **Step 9: Manual check.** `scripts/build-app.sh debug && pkill -x CaptureStudio; open dist/CaptureStudio.app`. Open a recording, add a zoom block over a stretch with cursor travel: the frame holds, glides, holds; with a 9:16 crop, with a framing window, and in fit mode the cursor stays in frame while the camera holds; with a cut inside the block the camera jumps with the picture; switching a block to Manual at the playhead does not shift the frame.

---

### Task 5: Activity extraction and suggester

**Files:**
- Create: `Sources/CaptureStudio/Studio/ZoomActivity.swift`, `Sources/CaptureStudio/Studio/AutoZoomSuggester.swift`
- Test: `Tests/CaptureStudioTests/ZoomActivityTests.swift`, `Tests/CaptureStudioTests/AutoZoomSuggesterTests.swift`

**Interfaces — Produces:**

```swift
struct TimeSpan: Equatable { var begin: Double; var end: Double }
struct ZoomActivity: Equatable {
    var clicks: [ClickSample] = []       // inside source bounds, excluding the down of a drag
    var drags: [TimeSpan] = []           // down→up moving > 1% of source width
    var typing: [TimeSpan] = []          // ≥ 3 keys, gaps ≤ 1.0 s, keys with "cmd" or "ctrl" ignored; key x/y is not used or bounds-checked
    var scrolls: [TimeSpan] = []         // gaps ≤ 0.3 s
    var isEmpty: Bool                    // no clicks, drags or typing (scrolls alone do not count)
    static func from(events: [EventLine], display: DisplayInfo, sourceSize: CGSize) -> ZoomActivity
}

struct AutoZoomSuggestConfig {
    var rampIn: Double; var rampOut: Double      // AutoZoomTrack.rampFor(defaultSensitivity) for both
    var postHold = 1.2, minWide = 1.0, preRollPad = 0.2, scrollSplit = 0.5
    var typingMin = 1.0, typingClickWindow = 10.0, minHold = 1.0
    var preRoll: Double { rampIn + preRollPad }
    var joinGap: Double { postHold + preRoll + minWide }
    var minLength: Double { rampIn + rampOut + minHold }
}

enum AutoZoomSuggester {
    static func suggest(activity: ZoomActivity, cursorSamples: [CursorSample],
                        span: ClosedRange<Double>, sourceSize: CGSize,
                        cuts: [Range<Double>], config: AutoZoomSuggestConfig) -> [ZoomBlock]
}
```

**Rules pinned beyond the spec's "Rules" section:**

- Work on the cut timeline: map every activity time, scroll span and `span` through `TimelineCut` (`point` for instants, `span` for ranges; anything inside a cut is dropped), run the rules below in collapsed time, then convert each resulting block's `begin` / `end` back with `TimelineCut.unmap`. With no cuts this is the identity.
- Activity items are `(begin, end)`: click `(t, t)`, drag, typing. Drop items whose `begin` is outside `span`, and items overlapping a scroll burst of length ≥ `scrollSplit`.
- Cluster gap = `next.begin − current.end`; join when ≤ `joinGap` and no splitting scroll lies between them.
- Run limits: lower = max(`span.lowerBound`, end of the nearest splitting scroll before the cluster); upper = min(`span.upperBound`, start of the nearest splitting scroll after it). `begin = max(first.begin − preRoll, lower)`, `end = min(last.end + postHold, upper)`.
- If `end − begin < minLength`: extend `end` up to `upper`, then `begin` down to `lower`; if still short, drop the run.
- Then, in time order: if a run begins less than `minWide` after the previous kept run ends and no splitting scroll lies between them, merge it into the previous run (previous `end` = this `end`).
- Typing split: for each typing span of length ≥ `typingMin` inside a run, cut the run into touching blocks at the span's edges; a leftover piece narrower than `ZoomTimeline.splitMinWidth` is absorbed into the typing block. The typing block gets `mode: .manual` and `focusX/Y` = (last click with `t` in `[typing.begin − typingClickWindow, typing.begin]`, else the cursor at `typing.begin`) divided by `sourceSize`, clamped to 0…1.
- All other blocks: every optional field nil.

- [ ] **Step 1: Write failing tests** — `ZoomActivityTests`:

```swift
@Test func clicksOutsideSourceAreDropped()
@Test func downUpWithTravelIsADragNotAClick()     // 300 px travel on 1920 wide → drags.count 1, clicks.count 0
@Test func threeKeysWithinGapFormTypingBurst()    // keys at 1.0, 1.4, 1.9 → typing == [1.0…1.9]; two keys → none
@Test func shortcutKeysAreNotTyping()             // 5 keys each with mods ["cmd"] → typing empty
@Test func scrollEventsGroupByGap()               // scrolls at 1.0,1.1,1.2, 3.0,3.1 → two spans
@Test func scrollOnlyActivityIsEmpty()
```

`AutoZoomSuggesterTests` (config: `rampIn = rampOut = 0.475`; so `preRoll` 0.675, `joinGap` 2.875, `minLength` 1.95; span `0...60`):

```swift
@Test func noActivityGivesNoBlocks()
@Test func singleClickGivesMinLengthBlockLandingBeforeClick()
    // click at 10 → one block; begin ≈ 10 − 0.675; end − begin ≥ 1.95 − 1e-9; begin + rampIn ≤ 10
@Test func clicksWithinJoinGapShareOneBlock()      // clicks at 10 and 12.5 → 1 block
@Test func clicksBeyondJoinGapLeaveMinWideBetween() // clicks at 10 and 13.5 → 2 blocks; gap between ≥ 1.0 − 1e-9
@Test func minLengthExtensionNeverClosesTheGap()    // clicks at 10 and 12.9 → either 1 merged block or 2 with gap ≥ 1.0 − 1e-9
@Test func clicksAdjacentAcrossACutShareOneRun()
    // click at 10, cuts [11.5..<40], click at 40.3 → after TimelineCut.span-collapsing the result, exactly one
    // contiguous zoomed span covers collapsed 10 and 11.8
@Test func longScrollSplitsEvenWhenClicksAreClose()
    // clicks at 10 and 12, scroll 10.6…11.4 → 2 blocks (or the short one dropped), none overlapping 10.6…11.4
@Test func shortScrollDoesNotSplit()               // scroll 10.6…10.9 → 1 block
@Test func typingBurstBecomesManualBlockOnPrecedingClick()
    // click at 10 at (960,540); typing 10.5…13 → 3 touching blocks or 2; the block covering 11.5 is .manual with focus (0.5, 0.5)
@Test func shortTypingBurstStaysFollow()           // typing 10.5…11.2 → no manual block
@Test func noKeysStillClustersClicks()             // Review Focus 4: typing empty, clicks present → blocks produced
@Test func eventsInsideCutsAreIgnored()            // click at 10, cuts [9..<11] → []
@Test func outputSortedNonOverlappingInsideSpan()  // 40 seeded random clicks, span 5...50
@Test func spanLimitsActivityAndResults()          // clicks at 10 and 30, span 28...33 → 1 block inside 28...33
@Test func spanTooShortForMinLengthGivesNothing()  // click at 10, span 9.5...10.5 → []
@Test func generatedFollowBlocksLeaveOptionalsNil()
```

- [ ] **Step 2: Run** `swift test --filter "ZoomActivityTests|AutoZoomSuggesterTests"` — expected: fail to compile.
- [ ] **Step 3: Implement** `ZoomActivity.from` (reuse `CursorOverlay.sourcePoint` for coordinates).
- [ ] **Step 4: Implement** `AutoZoomSuggester.suggest`.
- [ ] **Step 5: Run** the same filter — expected: all pass.

---

### Task 6: "Auto zoom" action and UI

**Files:**
- Modify: `Sources/CaptureStudio/Studio/AutoZoomSuggester.swift`, `Sources/CaptureStudio/Studio/StudioModel.swift` (`loadOverlayData` ~line 761; zoom section ~line 1146), `Sources/CaptureStudio/Studio/Inspector/ZoomInspector.swift`
- Test: `Tests/CaptureStudioTests/AutoZoomSuggesterTests.swift`

**Interfaces:**
- Consumes: Task 5 `suggest`, `ZoomActivity`.
- Produces:

```swift
enum AutoZoomScope: Equatable { case all; case block(UUID) }

extension AutoZoomSuggester {
    /// Time range a scope covers; nil when `.block` names an id not in `existing`.
    static func span(for scope: AutoZoomScope, existing: [ZoomBlock], duration: Double) -> ClosedRange<Double>?
    /// `.all` → `generated`. `.block(id)` → `existing` with that block replaced by `generated`, sorted by begin.
    static func merge(existing: [ZoomBlock], generated: [ZoomBlock], scope: AutoZoomScope) -> [ZoomBlock]
}

// StudioModel
private(set) var zoomActivity = ZoomActivity()
var canAutoZoom: Bool { hasCursorData }
/// Returns false (and changes nothing) when the scope is invalid or nothing was generated.
@discardableResult func generateAutoZoom(scope: AutoZoomScope) -> Bool
```

- [ ] **Step 1: Write failing tests**

```swift
@Test func allScopeSpansWholeRecording()          // span(.all, [], 42) == 0...42
@Test func blockScopeSpansThatBlock()             // block 5…9 → 5...9
@Test func blockScopeWithUnknownIDIsNoOp()        // Review Focus 5: span == nil
@Test func mergeAllReplacesEverything()
@Test func mergeBlockReplacesOnlyThatBlock()      // existing A(0…2) B(5…9) C(12…14), generated X(6…8) for B → [A, X, C], A and C equal to before
@Test func nothingFoundLeavesBlocksUntouched()    // Review Focus 4: suggest → [] ⇒ caller keeps `existing`; assert via a small pure helper
                                                  // `resolve(existing:generated:scope:) -> [ZoomBlock]?` returning nil for empty `generated`
```

- [ ] **Step 2: Run** `swift test --filter AutoZoomSuggesterTests` — expected: fail to compile.
- [ ] **Step 3: Implement** `AutoZoomScope`, `span(for:)`, `merge`, `resolve` (nil when `generated` is empty or the scope's span is nil; otherwise `merge`).
- [ ] **Step 4: Load activity.** In `loadOverlayData`, set `zoomActivity = ZoomActivity.from(...)` with every item past `duration + 0.001` removed; reset it to empty on the no-events path.
- [ ] **Step 5: Implement `generateAutoZoom(scope:)`.** Build the config from `AutoZoomTrack.rampFor(autoZoomConfig.defaultSensitivity)`, pass `cuts: TimelineSegments.cutRanges(segments)`, call `suggest` then `resolve`; on a non-nil result call `setZoomBlocks(result, select: nil)` (one `saveEdit`, so one undo step) and return true.
- [ ] **Step 6: Inspector UI.** Next to "Add zoom": `Button` labelled `Label("Auto zoom", systemImage: "wand.and.stars")`, disabled when `!model.canAutoZoom`, help `"Create zoom blocks from clicks and typing in this recording"` (or `"Zoom needs cursor data from a screen recording"` when disabled). Tap behaviour:
  - `model.zoomBlocks.isEmpty` → `generateAutoZoom(scope: .all)`.
  - otherwise present a `.confirmationDialog("Auto zoom", ...)` (same pattern as `CaptionsInspector.swift:206`) with buttons `"All blocks (replace \(n))"` → `.all`; `"Only this block"` → `.block(id)`, shown only when `model.selectedZoomBlockID` is set; and Cancel.
  - When the call returns false, show a caption under the button for this view's lifetime: `"No clicks or typing found in this range."`; clear it on the next successful run.
- [ ] **Step 7: Run** `swift build && swift test` — expected: all pass.
- [ ] **Step 8: Manual check.** Rebuild and relaunch. On a click-heavy recording: Auto zoom creates blocks that land before clicks; ⌘Z removes them in one step; with a block selected, "Only this block" leaves the others unchanged; a recording with typing produces a held frame while typing.

---

### Task 7: Full verification

- [ ] **Step 1:** `swift build && swift test` — expected: 0 failures.
- [ ] **Step 2:** `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test` — expected: 0 failures.
- [ ] **Step 3:** `grep -n "^import" Sources/CaptureStudio/Studio/ZoomShotPlanner.swift Sources/CaptureStudio/Studio/AutoZoomSuggester.swift Sources/CaptureStudio/Studio/ZoomActivity.swift` — expected: only `Foundation` and `CoreGraphics`.
- [ ] **Step 4:** `git diff --stat -- Sources/CaptureStudio/Studio/CameraCompositor.swift Sources/CaptureStudio/ProjectBundle` — expected: empty.
- [ ] **Step 5:** `scripts/build-app.sh release`, relaunch, export one project that has zoom blocks and a cut; confirm the exported camera path matches the preview.
- [ ] **Step 6:** Report results and ask the user whether to commit (message in normal English, ending with the project's `Co-Authored-By` line).
