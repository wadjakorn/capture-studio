# Auto Zoom/Pan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an automatic zoom/pan feature to the Studio editor — a dedicated timeline lane of "zoom blocks" that, during their spans, zoom the canvas and pan to follow the cursor with smooth, anticipatory animation; outside the blocks the canvas is untouched.

**Architecture:** Persist `ZoomBlock`s in `EditState`. A pure pre-pass (`AutoZoomTrack.build`) turns blocks + the already-loaded 60 Hz cursor samples into a smoothed `[ZoomKeyframe]` track at composition-build time. The compositor interpolates that track per frame (stateless, seek-safe — same pattern as `cursorSamples`) and applies a magnify-around-focus transform to the screen + cursor + click layers only (camera PiP and text stay fixed). A new timeline lane mirrors the existing `CameraTimelineLane`.

**Tech Stack:** Swift 6 (Command Line Tools toolchain), SwiftUI, Core Image / AVFoundation custom video compositor, swift-testing.

## Global Constraints

- Toolchain: **Command Line Tools only — no Xcode.app.** Do NOT bump pinned deps (swift-testing `0.12.0` exact, KeyboardShortcuts `1.10.0` exact).
- Build/test: `swift build`, `swift test`. Keep all existing tests green (109 at baseline).
- Tests use **swift-testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), `@testable import CaptureStudio`.
- Pure helpers are unit-tested; capture/UI/compositor glue is NOT unit-tested (project convention) — verify glue by building and running.
- Bundle id `dev.wadjakorn.capture-studio`; target macOS 15+.
- **Never commit or push without explicit user confirmation.** Commit messages in normal English, end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Persistence is forward/backward compatible: new `edit.json` fields must decode to defaults on older bundles (use `decodeIfPresent`).
- Decisions locked in design (`docs/superpowers/specs/2026-06-23-auto-zoom-pan-design.md`):
  - Zoom blocks are **non-overlapping** (like `CameraBlock`).
  - Idle (cursor still) → **hold zoom, freeze pan**.
  - Per-block `scale` override; falls back to a **global default** (UserDefaults `autoZoomDefaultScale`, default `2.0`).
  - Anticipation lead ~`0.4s`; ramps ~`0.4s`.
  - Auto-zoom magnifies **screen + cursor + click rings only**; camera PiP and text are NOT zoomed.

---

## File Structure

**New files:**
- `Sources/CaptureStudio/Studio/AutoZoom.swift` — `ZoomKeyframe`, `AutoZoomConfig`, `AutoZoomTrack` (pure pre-pass + sampler). Unit-tested.
- `Sources/CaptureStudio/Studio/ZoomTimeline.swift` — pure block math (add/move/resize/remove, non-overlap clamps). Unit-tested.
- `Sources/CaptureStudio/Studio/ZoomTimelineLane.swift` — SwiftUI lane view (glue).
- `Tests/CaptureStudioTests/ZoomTimelineTests.swift`
- `Tests/CaptureStudioTests/AutoZoomTrackTests.swift`

**Modified files:**
- `Sources/CaptureStudio/ProjectBundle/EditState.swift` — add `ZoomBlock` struct + `EditState.zoomBlocks`.
- `Tests/CaptureStudioTests/EditStateTests.swift` — round-trip `zoomBlocks`.
- `Sources/CaptureStudio/Studio/CameraCompositor.swift` — `OverlayPayload.autoZoom`, `magnify` helper, apply in `startRequest`.
- `Sources/CaptureStudio/Studio/StudioModel.swift` — `zoomBlocks` state, edit ops, load/save, `needsCompositor`, build the track, config.
- `Sources/CaptureStudio/Studio/StudioWindow.swift` — zoom lane row + add/delete/scale controls.

---

## Task 1: `ZoomBlock` model + persistence

**Files:**
- Modify: `Sources/CaptureStudio/ProjectBundle/EditState.swift` (add struct after `CameraBlock` ~line 118; add field after `textBlocks` ~line 320; init param ~line 338/367; decode ~line 410)
- Test: `Tests/CaptureStudioTests/EditStateTests.swift`

**Interfaces:**
- Produces: `struct ZoomBlock: Codable, Equatable, Identifiable { var id: UUID; var begin: Double; var end: Double; var scale: Double? }` with `init(id: UUID = UUID(), begin: Double, end: Double, scale: Double? = nil)`. `EditState.zoomBlocks: [ZoomBlock]` (default `[]`), persisted in `edit.json`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CaptureStudioTests/EditStateTests.swift` (inside its `@Suite`):

```swift
@Test func zoomBlocksRoundTrip() throws {
    var state = EditState()
    state.zoomBlocks = [
        ZoomBlock(begin: 1, end: 3, scale: 2.5),
        ZoomBlock(begin: 4, end: 6, scale: nil),
    ]
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(EditState.self, from: data)
    #expect(decoded.zoomBlocks == state.zoomBlocks)
    #expect(decoded.zoomBlocks[1].scale == nil)
}

@Test func zoomBlocksDefaultEmptyOnOldBundle() throws {
    // edit.json written before zoomBlocks existed → decodes to [].
    let json = #"{"schemaVersion":1,"trimIn":0}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(EditState.self, from: json)
    #expect(decoded.zoomBlocks.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EditStateTests`
Expected: FAIL — `value of type 'EditState' has no member 'zoomBlocks'` / `cannot find 'ZoomBlock'`.

- [ ] **Step 3: Add the `ZoomBlock` struct**

In `Sources/CaptureStudio/ProjectBundle/EditState.swift`, after the `CameraBlock` struct (after line 118), add:

```swift
/// One auto-zoom span on the screen-track timeline. During `[begin, end)` the
/// canvas zooms in and pans to follow the cursor (see `AutoZoomTrack`). Blocks
/// never overlap (a single zoom state at a time), mirroring `CameraBlock`.
/// `scale` is the target magnification (≥1); nil means use the global default
/// (`autoZoomDefaultScale`).
struct ZoomBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double
    var end: Double
    var scale: Double?

    init(id: UUID = UUID(), begin: Double, end: Double, scale: Double? = nil) {
        self.id = id
        self.begin = begin
        self.end = end
        self.scale = scale
    }
}
```

- [ ] **Step 4: Add the `EditState.zoomBlocks` field**

In `EditState`, after the `textBlocks` property (after line 320), add:

```swift
    /// Auto-zoom blocks. Empty = no auto zoom/pan. Non-overlapping; during each
    /// block the canvas zooms + pans to follow the cursor.
    var zoomBlocks: [ZoomBlock] = []
```

In the memberwise `init` (the one starting line 322), add `zoomBlocks: [ZoomBlock] = []` as the final parameter (after `textBlocks: [TextBlock] = []`) and, in the body (after `self.textBlocks = textBlocks` at line 368), add:

```swift
        self.zoomBlocks = zoomBlocks
```

In the custom `init(from:)` decode, after the `textBlocks` line (line 410), add:

```swift
        zoomBlocks = try c.decodeIfPresent([ZoomBlock].self, forKey: .zoomBlocks) ?? []
```

(`CodingKeys` is synthesized from the stored properties, so `.zoomBlocks` resolves automatically; the synthesized encoder writes it.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter EditStateTests`
Expected: PASS (including the two new tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/ProjectBundle/EditState.swift Tests/CaptureStudioTests/EditStateTests.swift
git commit -m "Add ZoomBlock model and persist EditState.zoomBlocks

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: `ZoomTimeline` block math

**Files:**
- Create: `Sources/CaptureStudio/Studio/ZoomTimeline.swift`
- Test: `Tests/CaptureStudioTests/ZoomTimelineTests.swift`

**Interfaces:**
- Consumes: `ZoomBlock` (Task 1).
- Produces: `enum ZoomTimeline` with:
  - `static func add(_ blocks: [ZoomBlock], atTime: Double, width: Double, duration: Double) -> (blocks: [ZoomBlock], id: UUID)`
  - `static func moveBegin(_ blocks: [ZoomBlock], id: UUID, toTime: Double, duration: Double) -> [ZoomBlock]`
  - `static func moveEnd(_ blocks: [ZoomBlock], id: UUID, toTime: Double, duration: Double) -> [ZoomBlock]`
  - `static func moveBlock(_ blocks: [ZoomBlock], id: UUID, toBegin: Double, duration: Double) -> [ZoomBlock]`
  - `static func remove(_ blocks: [ZoomBlock], id: UUID) -> [ZoomBlock]`
  - All results sorted by `begin`, non-overlapping.

- [ ] **Step 1: Write the failing test**

Create `Tests/CaptureStudioTests/ZoomTimelineTests.swift`:

```swift
import Testing
import Foundation
@testable import CaptureStudio

@Suite struct ZoomTimelineTests {
    private func block(_ begin: Double, _ end: Double, scale: Double? = nil) -> ZoomBlock {
        ZoomBlock(begin: begin, end: end, scale: scale)
    }

    @Test func addClampsIntoClip() {
        let (blocks, id) = ZoomTimeline.add([], atTime: 5, width: 2, duration: 10)
        let b = blocks.first { $0.id == id }!
        #expect(b.begin == 5)
        #expect(b.end == 7)
    }

    @Test func addPastDurationClampsEnd() {
        let (blocks, id) = ZoomTimeline.add([], atTime: 9.5, width: 2, duration: 10)
        let b = blocks.first { $0.id == id }!
        #expect(b.begin == 9.5)
        #expect(b.end == 10)
    }

    @Test func addCannotOverlapNextBlock() {
        let existing = [block(6, 8)]
        let (blocks, id) = ZoomTimeline.add(existing, atTime: 5, width: 5, duration: 10)
        let b = blocks.first { $0.id == id }!
        #expect(b.begin == 5)
        #expect(b.end == 6)   // clamped to the next block's begin
    }

    @Test func moveBeginCannotCrossPreviousEnd() {
        let a = block(0, 2)
        let bId = UUID()
        let b = ZoomBlock(id: bId, begin: 3, end: 5)
        let out = ZoomTimeline.moveBegin([a, b], id: bId, toTime: 1, duration: 10)
        let moved = out.first { $0.id == bId }!
        #expect(moved.begin == 2)   // clamped to a.end
    }

    @Test func moveEndCannotCrossNextBegin() {
        let aId = UUID()
        let a = ZoomBlock(id: aId, begin: 0, end: 2)
        let b = block(3, 5)
        let out = ZoomTimeline.moveEnd([a, b], id: aId, toTime: 4, duration: 10)
        let moved = out.first { $0.id == aId }!
        #expect(moved.end == 3)     // clamped to b.begin
    }

    @Test func moveBlockKeepsWidthAndStaysInsideNeighbors() {
        let a = block(0, 2)
        let cId = UUID()
        let c = ZoomBlock(id: cId, begin: 3, end: 4)   // width 1
        let out = ZoomTimeline.moveBlock([a, c], id: cId, toBegin: 0.5, duration: 10)
        let moved = out.first { $0.id == cId }!
        #expect(moved.begin == 2)       // clamped to a.end
        #expect(moved.end == 3)         // width preserved
    }

    @Test func removeDropsBlock() {
        let aId = UUID()
        let a = ZoomBlock(id: aId, begin: 0, end: 2)
        let out = ZoomTimeline.remove([a, block(3, 5)], id: aId)
        #expect(out.count == 1)
        #expect(!out.contains { $0.id == aId })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ZoomTimelineTests`
Expected: FAIL — `cannot find 'ZoomTimeline' in scope`.

- [ ] **Step 3: Implement `ZoomTimeline`**

Create `Sources/CaptureStudio/Studio/ZoomTimeline.swift`:

```swift
import Foundation

/// Pure block math for the auto-zoom timeline: add / move / resize / remove
/// operations the lane UI drives. Blocks are non-overlapping spans (a single
/// zoom state at a time), so the clamps here guarantee no overlap. Mirrors
/// `CameraTimeline`'s edge logic. No AVFoundation, no UI — all unit-tested.
enum ZoomTimeline {
    // MARK: - Edge clamps (non-overlap)

    static func clampBegin(_ blocks: [ZoomBlock], id: UUID, toTime: Double,
                           duration: Double) -> Double {
        let sorted = sortedByBegin(blocks)
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return toTime }
        let lower = i > 0 ? sorted[i - 1].end : 0
        let upper = sorted[i].end
        return min(max(toTime, lower), upper)
    }

    static func clampEnd(_ blocks: [ZoomBlock], id: UUID, toTime: Double,
                         duration: Double) -> Double {
        let sorted = sortedByBegin(blocks)
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return toTime }
        let lower = sorted[i].begin
        let upper = i + 1 < sorted.count ? sorted[i + 1].begin : duration
        return min(max(toTime, lower), upper)
    }

    // MARK: - Operations

    static func moveBegin(_ blocks: [ZoomBlock], id: UUID, toTime: Double,
                          duration: Double) -> [ZoomBlock] {
        let t = clampBegin(blocks, id: id, toTime: toTime, duration: duration)
        return sortedByBegin(blocks.map { $0.id == id ? with($0, begin: t) : $0 })
    }

    static func moveEnd(_ blocks: [ZoomBlock], id: UUID, toTime: Double,
                        duration: Double) -> [ZoomBlock] {
        let t = clampEnd(blocks, id: id, toTime: toTime, duration: duration)
        return sortedByBegin(blocks.map { $0.id == id ? with($0, end: t) : $0 })
    }

    static func moveBlock(_ blocks: [ZoomBlock], id: UUID, toBegin: Double,
                          duration: Double) -> [ZoomBlock] {
        let sorted = sortedByBegin(blocks)
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return sorted }
        let width = sorted[i].end - sorted[i].begin
        let lower = i > 0 ? sorted[i - 1].end : 0
        let upperBegin = (i + 1 < sorted.count ? sorted[i + 1].begin : duration) - width
        let begin = min(max(toBegin, lower), max(lower, upperBegin))
        return sortedByBegin(sorted.map {
            $0.id == id ? with($0, begin: begin, end: begin + width) : $0
        })
    }

    static func remove(_ blocks: [ZoomBlock], id: UUID) -> [ZoomBlock] {
        blocks.filter { $0.id != id }
    }

    /// Insert a `width`-wide block at `atTime`, clamped past any block it lands
    /// inside and against the next block / duration, so the result never overlaps.
    static func add(_ blocks: [ZoomBlock], atTime: Double, width: Double,
                    duration: Double) -> (blocks: [ZoomBlock], id: UUID) {
        let lowerBound = blocks.filter { $0.begin <= atTime }.map(\.end).max() ?? 0
        let begin = min(max(atTime, lowerBound, 0), max(0, duration))
        let nextBegin = blocks.filter { $0.begin > begin }.map(\.begin).min() ?? duration
        let end = min(begin + max(0, width), nextBegin, duration)
        let block = ZoomBlock(begin: begin, end: max(begin, end))
        return (sortedByBegin(blocks + [block]), block.id)
    }

    // MARK: - Helpers

    private static func sortedByBegin(_ blocks: [ZoomBlock]) -> [ZoomBlock] {
        blocks.sorted { $0.begin < $1.begin }
    }

    private static func with(_ b: ZoomBlock, begin: Double? = nil,
                             end: Double? = nil) -> ZoomBlock {
        var c = b
        if let begin { c.begin = begin }
        if let end { c.end = end }
        return c
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ZoomTimelineTests`
Expected: PASS (all 7).

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/ZoomTimeline.swift Tests/CaptureStudioTests/ZoomTimelineTests.swift
git commit -m "Add ZoomTimeline block math (non-overlapping)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: `AutoZoomTrack` pre-pass + sampler

**Files:**
- Create: `Sources/CaptureStudio/Studio/AutoZoom.swift`
- Test: `Tests/CaptureStudioTests/AutoZoomTrackTests.swift`

**Interfaces:**
- Consumes: `ZoomBlock` (Task 1), `CursorSample` (existing, `CursorOverlay.swift`: `{ t: Double; p: CGPoint; cursor: String }`).
- Produces:
  - `struct ZoomKeyframe: Equatable { var t: Double; var scale: Double; var focusX: Double; var focusY: Double }`
  - `struct AutoZoomConfig { var defaultScale: Double; var lead: Double; var ramp: Double; var idleSpeed: Double; var smoothing: Double; var step: Double }` with defaults `2.0 / 0.4 / 0.4 / 40 / 0.12 / (1.0/60.0)`.
  - `enum AutoZoomTrack`:
    - `static func build(blocks: [ZoomBlock], cursorSamples: [CursorSample], sourceSize: CGSize, config: AutoZoomConfig = AutoZoomConfig()) -> [ZoomKeyframe]`
    - `static func sample(at t: Double, track: [ZoomKeyframe]) -> (scale: CGFloat, focus: CGPoint)` — returns `(1, .zero)` outside the track.

Notes on algorithm (locked decisions): scale smoothstep-ramps `1→S` over `ramp` at entry and `S→1` over `ramp` at exit (each clamped to ≤ ½ block length); focus targets the cursor position at `t + lead` (anticipation); when cursor speed `< idleSpeed` the target is frozen at the last value (hold zoom, freeze pan); focus is exponentially smoothed in a single forward pass and clamped to `[0, sourceSize]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CaptureStudioTests/AutoZoomTrackTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

@Suite struct AutoZoomTrackTests {
    private let source = CGSize(width: 1000, height: 1000)

    // A cursor that sits at x=200 until t=2, then jumps to x=800 by t=3.
    private func movingCursor() -> [CursorSample] {
        var s: [CursorSample] = []
        var t = 0.0
        while t <= 5.0 {
            let x: Double = t < 2 ? 200 : min(800, 200 + (t - 2) * 600)
            s.append(CursorSample(t: t, p: CGPoint(x: x, y: 500), cursor: "arrow"))
            t += 1.0 / 60.0
        }
        return s
    }

    private func sampleScale(_ track: [ZoomKeyframe], at t: Double) -> CGFloat {
        AutoZoomTrack.sample(at: t, track: track).scale
    }

    @Test func emptyBlocksProduceEmptyTrack() {
        let track = AutoZoomTrack.build(blocks: [], cursorSamples: movingCursor(),
                                        sourceSize: source)
        #expect(track.isEmpty)
        let s = AutoZoomTrack.sample(at: 1, track: track)
        #expect(s.scale == 1)
    }

    @Test func scaleIsOneOutsideBlocks() {
        let blocks = [ZoomBlock(begin: 1, end: 3, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        #expect(sampleScale(track, at: 0.5) == 1)   // before
        #expect(sampleScale(track, at: 4.0) == 1)   // after
    }

    @Test func scaleReachesTargetMidBlock() {
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        // Mid-block, past the entry ramp: full target scale.
        #expect(abs(sampleScale(track, at: 2.0) - 2.0) < 0.05)
    }

    @Test func perBlockScaleOverridesGlobalDefault() {
        var cfg = AutoZoomConfig(); cfg.defaultScale = 3
        let overridden = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2)],
                                             cursorSamples: movingCursor(),
                                             sourceSize: source, config: cfg)
        let usingDefault = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: nil)],
                                               cursorSamples: movingCursor(),
                                               sourceSize: source, config: cfg)
        #expect(abs(sampleScale(overridden, at: 2.0) - 2.0) < 0.05)
        #expect(abs(sampleScale(usingDefault, at: 2.0) - 3.0) < 0.05)
    }

    @Test func focusAnticipatesUpcomingMovement() {
        // Lead should pull focus toward the upcoming x=800 before t=2 (when the
        // cursor is still physically at x=200).
        var cfg = AutoZoomConfig(); cfg.lead = 0.4; cfg.smoothing = 0.05
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source, config: cfg)
        let focusJustBeforeMove = AutoZoomTrack.sample(at: 1.95, track: track).focus.x
        let focusAtStart = AutoZoomTrack.sample(at: 0.5, track: track).focus.x
        #expect(focusJustBeforeMove > focusAtStart + 1)   // already drifting toward 800
    }

    @Test func focusFreezesWhileCursorStill() {
        // From t=0 to ~1.5 the cursor is still (x=200): focus should be ~constant.
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source)
        let a = AutoZoomTrack.sample(at: 0.8, track: track).focus.x
        let b = AutoZoomTrack.sample(at: 1.4, track: track).focus.x
        #expect(abs(a - b) < 5)
    }

    @Test func emptyCursorSamplesCenterFocus() {
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: [],
                                        sourceSize: source)
        let f = AutoZoomTrack.sample(at: 2.0, track: track).focus
        #expect(abs(f.x - 500) < 1)
        #expect(abs(f.y - 500) < 1)
    }

    @Test func focusClampedToSourceBounds() {
        // Cursor far off the right edge; focus must not exceed source width.
        let s = [CursorSample(t: 0, p: CGPoint(x: 5000, y: 500), cursor: "arrow"),
                 CursorSample(t: 4, p: CGPoint(x: 5000, y: 500), cursor: "arrow")]
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2)],
                                        cursorSamples: s, sourceSize: source)
        let f = AutoZoomTrack.sample(at: 2.0, track: track).focus
        #expect(f.x <= 1000)
        #expect(f.x >= 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AutoZoomTrackTests`
Expected: FAIL — `cannot find 'AutoZoomTrack' in scope`.

- [ ] **Step 3: Implement `AutoZoom.swift`**

Create `Sources/CaptureStudio/Studio/AutoZoom.swift`:

```swift
import Foundation
import CoreGraphics

/// One resolved auto-zoom state at an instant: magnification (`scale`, ≥1) and
/// the focus point in screen-source pixels (top-left origin) the zoom centers on.
struct ZoomKeyframe: Equatable {
    var t: Double
    var scale: Double
    var focusX: Double
    var focusY: Double
}

/// Tunables for the auto-zoom pre-pass. Defaults are v1 values; `defaultScale`
/// is overridden per project from `autoZoomDefaultScale`.
struct AutoZoomConfig {
    var defaultScale: Double = 2.0
    /// Anticipation: focus targets the cursor position this many seconds ahead.
    var lead: Double = 0.4
    /// Zoom-in / zoom-out ramp duration (each end of a block).
    var ramp: Double = 0.4
    /// Cursor speed (source px/sec) below which the cursor is "still": the pan
    /// target freezes (hold zoom, freeze pan).
    var idleSpeed: Double = 40
    /// Exponential focus-smoothing time constant (seconds).
    var smoothing: Double = 0.12
    /// Keyframe sampling step (seconds).
    var step: Double = 1.0 / 60.0
}

/// Pure pre-pass: turn zoom blocks + cursor samples into a smoothed
/// `[ZoomKeyframe]` track, then sample it statelessly per frame. Building once
/// (at composition build) and interpolating at render time keeps the render
/// deterministic under out-of-order frame requests (preview scrubbing). No
/// AVFoundation / AppKit deps so it's unit-testable.
enum AutoZoomTrack {
    static func build(blocks: [ZoomBlock], cursorSamples: [CursorSample],
                      sourceSize: CGSize,
                      config: AutoZoomConfig = AutoZoomConfig()) -> [ZoomKeyframe] {
        guard !blocks.isEmpty else { return [] }
        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        let alpha = 1 - exp(-config.step / max(config.smoothing, 1e-4))
        var out: [ZoomKeyframe] = []

        for block in blocks.sorted(by: { $0.begin < $1.begin }) {
            let span = block.end - block.begin
            guard span > 0 else { continue }
            let target = max(1, block.scale ?? config.defaultScale)
            let ramp = min(config.ramp, span / 2)

            // Seed the smoothed focus on the cursor at the block start.
            var focus = cursorPoint(at: block.begin, in: cursorSamples) ?? center
            var lastTarget = focus

            var t = block.begin
            while t < block.end - 1e-9 {
                // Scale ramp (smoothstep in, hold, smoothstep out).
                let scale = scaleAt(t, begin: block.begin, end: block.end,
                                    ramp: ramp, target: target)
                // Anticipated, idle-gated target.
                let aheadT = min(t + config.lead, block.end)
                let raw = cursorPoint(at: aheadT, in: cursorSamples) ?? center
                let speed = cursorSpeed(at: t, in: cursorSamples, dt: config.step)
                let desired = speed < config.idleSpeed ? lastTarget : raw
                lastTarget = desired
                // Exponential smoothing toward the target, clamped to source.
                focus.x += (desired.x - focus.x) * alpha
                focus.y += (desired.y - focus.y) * alpha
                focus.x = min(max(focus.x, 0), sourceSize.width)
                focus.y = min(max(focus.y, 0), sourceSize.height)

                out.append(ZoomKeyframe(t: t, scale: scale,
                                        focusX: focus.x, focusY: focus.y))
                t += config.step
            }
            // Exact end keyframe (scale back to 1) for a clean handoff to the gap.
            out.append(ZoomKeyframe(t: block.end, scale: 1,
                                    focusX: focus.x, focusY: focus.y))
        }
        return out
    }

    /// Interpolate the track at `t`. Outside the track (gaps / ends) → no zoom.
    static func sample(at t: Double, track: [ZoomKeyframe]) -> (scale: CGFloat, focus: CGPoint) {
        guard let first = track.first, let last = track.last else { return (1, .zero) }
        if t <= first.t || t >= last.t { return (1, .zero) }

        var lo = 0, hi = track.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if track[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        let a = track[lo]
        let b = track[min(lo + 1, track.count - 1)]
        let span = b.t - a.t
        guard span > 0 else {
            return (CGFloat(a.scale), CGPoint(x: a.focusX, y: a.focusY))
        }
        let f = (t - a.t) / span
        let scale = a.scale + (b.scale - a.scale) * f
        let fx = a.focusX + (b.focusX - a.focusX) * f
        let fy = a.focusY + (b.focusY - a.focusY) * f
        return (CGFloat(scale), CGPoint(x: fx, y: fy))
    }

    // MARK: - Helpers

    private static func scaleAt(_ t: Double, begin: Double, end: Double,
                                ramp: Double, target: Double) -> Double {
        guard ramp > 1e-9 else { return target }
        if t < begin + ramp {
            return 1 + (target - 1) * smoothstep((t - begin) / ramp)
        }
        if t > end - ramp {
            return 1 + (target - 1) * smoothstep((end - t) / ramp)
        }
        return target
    }

    private static func smoothstep(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// Cursor position at `t` (source px), linearly interpolated; nil if empty.
    private static func cursorPoint(at t: Double, in samples: [CursorSample]) -> CGPoint? {
        CursorOverlay.position(at: t, in: samples)?.p
    }

    /// Cursor speed (source px/sec) around `t` via a centered difference.
    private static func cursorSpeed(at t: Double, in samples: [CursorSample],
                                    dt: Double) -> Double {
        guard let a = cursorPoint(at: t - dt, in: samples),
              let b = cursorPoint(at: t + dt, in: samples) else { return 0 }
        let dx = b.x - a.x, dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot() / (2 * dt)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AutoZoomTrackTests`
Expected: PASS (all 8). If `focusAnticipatesUpcomingMovement` is flaky at the boundary, it asserts only a `> +1` px drift — the lead must move focus measurably before the physical move; do not weaken below catching a real regression.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/AutoZoom.swift Tests/CaptureStudioTests/AutoZoomTrackTests.swift
git commit -m "Add AutoZoomTrack pre-pass and stateless sampler

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: Compositor — carry + apply the zoom track

**Files:**
- Modify: `Sources/CaptureStudio/Studio/CameraCompositor.swift` (`OverlayPayload` ~line 175; `startRequest` ~lines 271-302; add `magnify` helper near `sourceToCanvas` ~line 496)

**Interfaces:**
- Consumes: `ZoomKeyframe`, `AutoZoomTrack.sample` (Task 3); existing `screenPlacement`/`sourceToCanvas`.
- Produces: `OverlayPayload.autoZoom: [ZoomKeyframe]` (default `[]`). When non-empty, the screen + cursor + click layers are magnified per frame around the interpolated focus.

This task is compositor glue (not unit-tested). Verify by building; visual behavior is verified in Task 7.

- [ ] **Step 1: Add the payload field**

In `CameraCompositor.swift`, in `struct OverlayPayload` (after `clickSamples` line 177), add:

```swift
    /// Pre-built auto-zoom track (screen-source focus + magnification per time).
    /// Empty = no auto zoom/pan. Interpolated per frame; see `AutoZoomTrack`.
    var autoZoom: [ZoomKeyframe] = []
```

- [ ] **Step 2: Add the `magnify` helper**

In `final class StudioCompositor`, after `sourceToCanvas(_:layout:)` (after line 496), add:

```swift
    /// Magnify an already-placed canvas-space image by `scale` around a canvas
    /// focus point (top-left origin). Identity when `scale <= 1`. Used to apply
    /// auto-zoom to the screen + cursor + click layers (camera/text are not
    /// passed through this, so they stay fixed).
    private static func magnify(_ image: CIImage, scale: CGFloat,
                                focusCanvas: CGPoint, canvas: CGSize) -> CIImage {
        guard scale > 1.0001 else { return image }
        let fx = focusCanvas.x
        let fy = canvas.height - focusCanvas.y          // top-left → CI bottom-left
        let t = CGAffineTransform(translationX: -fx, y: -fy)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: fx, y: fy))
        return image.transformed(by: t)
    }
```

- [ ] **Step 3: Apply the zoom in `startRequest`**

In `startRequest`, replace the block from `var output = screenCanvasImage(...)` through the cursor composite (current lines 271-291) with:

```swift
            let now = request.compositionTime.seconds

            // Resolve auto-zoom for this frame (identity when scale == 1).
            let zoom = AutoZoomTrack.sample(at: now, track: instruction.overlay.autoZoom)
            let focusCanvas = Self.sourceToCanvas(zoom.focus, layout: layout)
            func zoomed(_ img: CIImage) -> CIImage {
                Self.magnify(img, scale: zoom.scale, focusCanvas: focusCanvas,
                             canvas: layout.canvas)
            }

            var output = zoomed(screenCanvasImage(screenBuf, layout: layout,
                                                  backgroundImage: instruction.overlay.backgroundImage))

            if let cameraID = layout.cameraTrackID,
               let cameraBuf = request.sourceFrame(byTrackID: cameraID),
               let camera = cameraImage(cameraBuf, at: now, layout: layout,
                                        instruction: instruction) {
                output = camera.composited(over: output)   // camera is NOT zoomed
            }

            // Click rings sit under the cursor; both ride the screen zoom.
            if layout.clickFeedback {
                for ring in clickRings(at: now, layout: layout, overlay: instruction.overlay) {
                    output = zoomed(ring).composited(over: output)
                }
            }
            if layout.showCursor, let cursor = cursorImage(at: now, layout: layout,
                                                           overlay: instruction.overlay) {
                output = zoomed(cursor).composited(over: output)
            }
```

(The `now` declaration moves up; delete the original `let now = request.compositionTime.seconds` at old line 273 so it isn't declared twice. Text/caption compositing and the final `output.cropped(to: canvas)` at line 304 stay unchanged — text is not zoomed, and the final crop trims the enlarged screen.)

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Builds with no errors.

- [ ] **Step 5: Run the full test suite (no regressions)**

Run: `swift test`
Expected: All tests pass (baseline + new from Tasks 1-3).

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/Studio/CameraCompositor.swift
git commit -m "Apply per-frame auto-zoom to screen, cursor, and click layers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: StudioModel — state, edit ops, load/save, track build

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (state ~lines 47-54; `needsCompositor` ~line 264; load ~line 351; camera-block ops region ~lines 630-700/935-955; `buildCompositorComposition` ~line 1356; `saveEdit` ~line 1517)

**Interfaces:**
- Consumes: `ZoomTimeline` (Task 2), `AutoZoomTrack`/`AutoZoomConfig` (Task 3), `OverlayPayload.autoZoom` (Task 4), `ZoomBlock`/`EditState.zoomBlocks` (Task 1).
- Produces (used by Task 6 UI):
  - `@Published private(set) var zoomBlocks: [ZoomBlock]`
  - `@Published var selectedZoomBlockID: UUID?`
  - `var showsZoomTimeline: Bool`
  - `func addZoomBlock()`, `func removeZoomBlock(_ id: UUID)`, `func selectZoomBlock(_ id: UUID?)`
  - `func moveZoomBlockBegin(_ id: UUID, toTime: Double)`, `func moveZoomBlockEnd(_ id: UUID, toTime: Double)`, `func moveZoomBlock(_ id: UUID, toBegin: Double)`, `func commitZoomEdit()`
  - `var selectedZoomScale: Double` / `func setZoomScale(_ v: Double)` / `func resetZoomScale()`

Model wiring is glue (not unit-tested); verify by building + Task 7.

- [ ] **Step 1: Add published state**

After `selectedBlockID` / near the camera-block state (after line 48), add:

```swift
    @Published private(set) var zoomBlocks: [ZoomBlock] = []
    @Published var selectedZoomBlockID: UUID?
```

Add the visibility helper near `showsCameraTimeline` (after line 103):

```swift
    /// The zoom lane is shown only when there is at least one zoom block.
    var showsZoomTimeline: Bool { !zoomBlocks.isEmpty }

    /// Per-project default magnification for new/unset blocks (global config).
    var autoZoomConfig: AutoZoomConfig {
        var c = AutoZoomConfig()
        let v = UserDefaults.standard.double(forKey: "autoZoomDefaultScale")
        if v > 1 { c.defaultScale = v }
        return c
    }
```

- [ ] **Step 2: Include zoom in `needsCompositor`**

In `needsCompositor` (lines 264-271), add a clause:

```swift
    var needsCompositor: Bool {
        cameraNeedsCompositor
            || cameraHasTimeline
            || !textBlocks.isEmpty
            || !zoomBlocks.isEmpty
            || (showCursor && hasCursorData)
            || (clickFeedback && hasClickData)
            || (cropAspect.isFit && canvasBackground != .black)
    }
```

- [ ] **Step 3: Load zoom blocks**

In the load path, after `textBlocks = edit.textBlocks` (line 351), add:

```swift
            zoomBlocks = edit.zoomBlocks.sorted { $0.begin < $1.begin }
```

- [ ] **Step 4: Save zoom blocks**

In `saveEdit()`, in the `EditState(...)` initializer (after `textBlocks: textBlocks` at line 1517), add the argument:

```swift
            textBlocks: textBlocks,
            zoomBlocks: zoomBlocks
```

(Change the previous line to end with a comma; `zoomBlocks` is the last argument.)

- [ ] **Step 5: Add the edit operations**

After the camera-block ops (after `toggleBlockVisible` ends at line 700), add a new section:

```swift
    // MARK: - Zoom timeline (auto zoom/pan blocks)

    /// Add a zoom block at the playhead (scale = nil → uses the global default).
    func addZoomBlock() {
        let t = min(max(currentTime, 0), duration)
        let added = ZoomTimeline.add(zoomBlocks, atTime: t,
                                     width: Self.defaultBlockWidth, duration: duration)
        setZoomBlocks(added.blocks, select: added.id)
    }

    func moveZoomBlockBegin(_ id: UUID, toTime: Double) {
        zoomBlocks = ZoomTimeline.moveBegin(zoomBlocks, id: id, toTime: toTime, duration: duration)
        applyVideoComposition()
    }

    func moveZoomBlockEnd(_ id: UUID, toTime: Double) {
        zoomBlocks = ZoomTimeline.moveEnd(zoomBlocks, id: id, toTime: toTime, duration: duration)
        applyVideoComposition()
    }

    func moveZoomBlock(_ id: UUID, toBegin: Double) {
        zoomBlocks = ZoomTimeline.moveBlock(zoomBlocks, id: id, toBegin: toBegin, duration: duration)
        applyVideoComposition()
    }

    func commitZoomEdit() { saveEdit() }

    func removeZoomBlock(_ id: UUID) {
        let list = ZoomTimeline.remove(zoomBlocks, id: id)
        setZoomBlocks(list, select: selectedZoomBlockID == id ? nil : selectedZoomBlockID)
    }

    /// Select a zoom block (clears camera/text selection) and park the playhead
    /// inside its span so the preview shows the zoom.
    func selectZoomBlock(_ id: UUID?) {
        selectedZoomBlockID = id
        if id != nil { selectedBlockID = nil; selectedTextBlockID = nil }
        if let id, let b = zoomBlocks.first(where: { $0.id == id }) {
            seek(to: min((b.begin + b.end) / 2, duration))
        }
    }

    /// Effective scale of the selected block (its override, else global default).
    var selectedZoomScale: Double {
        guard let id = selectedZoomBlockID,
              let b = zoomBlocks.first(where: { $0.id == id }) else {
            return autoZoomConfig.defaultScale
        }
        return b.scale ?? autoZoomConfig.defaultScale
    }

    /// Set the selected block's scale override (live; persist via commitZoomEdit).
    func setZoomScale(_ v: Double) {
        guard let id = selectedZoomBlockID,
              let i = zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        zoomBlocks[i].scale = min(max(1, v), 6)
        applyVideoComposition()
    }

    /// Clear the override so the block follows the global default again.
    func resetZoomScale() {
        guard let id = selectedZoomBlockID,
              let i = zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        zoomBlocks[i].scale = nil
        applyVideoComposition()
        saveEdit()
    }

    /// Replace the zoom-block list. Adding the first / removing the last flips
    /// the compositor on/off, so refresh the player item when `needsCompositor`
    /// changes, mirroring `setBlocks`.
    private func setZoomBlocks(_ list: [ZoomBlock], select id: UUID?) {
        let was = needsCompositor
        zoomBlocks = list
        selectedZoomBlockID = id
        if needsCompositor != was {
            refreshPlayerItemForCanvasChange()
        }
        applyVideoComposition()
        saveEdit()
    }
```

- [ ] **Step 6: Build the track in `buildCompositorComposition`**

In `buildCompositorComposition`, after the text-timeline block (after line 1374, before the `let instruction = ...`), add:

```swift
        // Auto zoom/pan: pre-build the smoothed track from blocks + cursor
        // samples (cursor data is loaded regardless of the showCursor toggle).
        if !zoomBlocks.isEmpty {
            overlay.autoZoom = AutoZoomTrack.build(blocks: zoomBlocks,
                                                   cursorSamples: cursorSamples,
                                                   sourceSize: sourceSize,
                                                   config: autoZoomConfig)
        }
```

- [ ] **Step 7: Build to verify it compiles**

Run: `swift build`
Expected: Builds with no errors.

- [ ] **Step 8: Run the full test suite**

Run: `swift test`
Expected: All tests pass (no regressions).

- [ ] **Step 9: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift
git commit -m "Wire zoom blocks into StudioModel: state, edit ops, load/save, track build

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: Timeline lane + controls UI

**Files:**
- Create: `Sources/CaptureStudio/Studio/ZoomTimelineLane.swift`
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` (lane stack ~line 124; controls near `cameraControls`/`textControls` ~lines 344-377)

**Interfaces:**
- Consumes: `StudioModel` zoom API (Task 5).
- Produces: `struct ZoomTimelineLane: View`; a zoom controls group in `StudioWindow`.

UI glue (not unit-tested); verify by building + Task 7.

- [ ] **Step 1: Create the lane view**

Create `Sources/CaptureStudio/Studio/ZoomTimelineLane.swift`:

```swift
import SwiftUI

/// The auto-zoom track: a strip under the main scrubber showing zoom blocks.
/// Each block spans its `[begin, end)` with draggable edge handles; the body
/// drags to reposition (keeping width); the empty track scrubs. Tapping selects
/// a block. Mirrors `CameraTimelineLane` (non-overlapping, single row).
struct ZoomTimelineLane: View {
    @ObservedObject var model: StudioModel

    private let laneHeight: CGFloat = 26
    private let handleWidth: CGFloat = 7
    private let laneSpace = "zoomLane"

    @State private var dragMoved = false
    @State private var dragStartBegin: Double = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)

                ForEach(model.zoomBlocks) { block in
                    blockView(block, width: width)
                }

                Rectangle()
                    .fill(.primary)
                    .frame(width: 2, height: laneHeight)
                    .offset(x: fraction(model.currentTime) * width - 1)
                    .allowsHitTesting(false)
            }
            .frame(height: laneHeight)
            .coordinateSpace(name: laneSpace)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
                    .onChanged { value in
                        model.seek(to: time(atX: value.location.x, width: width))
                    }
            )
        }
        .frame(height: laneHeight)
    }

    @ViewBuilder
    private func blockView(_ block: ZoomBlock, width: CGFloat) -> some View {
        let x0 = fraction(block.begin) * width
        let x1 = fraction(block.end) * width
        let selected = model.selectedZoomBlockID == block.id
        let accent = Color.orange     // distinct from camera (accent) + text lanes
        let bodyW = max(2, x1 - x0)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent.opacity(selected ? 0.5 : 0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? accent : .clear, lineWidth: 1.5)
                )
                .frame(width: bodyW, height: laneHeight - 2)
                .contentShape(Rectangle())
                .gesture(bodyGesture(block, width: width))

            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: bodyW, height: laneHeight - 2)
                .allowsHitTesting(false)

            edgeHandle(accent).position(x: 0, y: laneHeight / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: true))
            edgeHandle(accent).position(x: bodyW, y: laneHeight / 2)
                .highPriorityGesture(edgeGesture(block, width: width, isBegin: false))
        }
        .frame(width: bodyW, height: laneHeight, alignment: .leading)
        .offset(x: x0)
    }

    private func edgeHandle(_ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: handleWidth, height: laneHeight - 6)
            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: 16, height: laneHeight)
            .contentShape(Rectangle())
    }

    private func bodyGesture(_ block: ZoomBlock, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if !dragMoved, abs(value.translation.width) > 2 {
                    dragMoved = true
                    dragStartBegin = block.begin
                    model.selectedZoomBlockID = block.id
                }
                if dragMoved, width > 0 {
                    let dt = Double(value.translation.width / width) * model.duration
                    model.moveZoomBlock(block.id, toBegin: dragStartBegin + dt)
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitZoomEdit() } else { model.selectZoomBlock(block.id) }
                dragMoved = false
            }
    }

    private func edgeGesture(_ block: ZoomBlock, width: CGFloat, isBegin: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
            .onChanged { value in
                if abs(value.translation.width) > 2 { dragMoved = true }
                if dragMoved {
                    model.selectedZoomBlockID = block.id
                    let t = time(atX: value.location.x, width: width)
                    if isBegin { model.moveZoomBlockBegin(block.id, toTime: t) }
                    else { model.moveZoomBlockEnd(block.id, toTime: t) }
                }
            }
            .onEnded { _ in
                if dragMoved { model.commitZoomEdit() } else { model.selectZoomBlock(block.id) }
                dragMoved = false
            }
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(min(max(0, seconds / model.duration), 1))
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1)) * model.duration
    }
}
```

- [ ] **Step 2: Add the lane row to the stack**

In `StudioWindow.swift`, after the text lane row (after line 124), add:

```swift
            if model.showsZoomTimeline {
                laneRow("plus.magnifyingglass") { ZoomTimelineLane(model: model) }
            }
```

- [ ] **Step 3: Add zoom controls**

In `StudioWindow.swift`, add a controls group near `cameraControls` / `textControls`. After the `textControls` computed property (after it ends ~line 380), add:

```swift
    @ViewBuilder private var zoomControls: some View {
        Button { model.addZoomBlock() } label: {
            Label("Add zoom", systemImage: "plus.magnifyingglass")
        }
        .help("Add an auto zoom/pan block at the playhead")

        Button {
            if let id = model.selectedZoomBlockID { model.removeZoomBlock(id) }
        } label: {
            Image(systemName: "minus.magnifyingglass")
        }
        .disabled(model.selectedZoomBlockID == nil)
        .help("Delete the selected zoom block")

        if model.selectedZoomBlockID != nil {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { model.selectedZoomScale },
                                   set: { model.setZoomScale($0) }),
                    in: 1...6,
                    onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
                )
                .frame(width: 90)
                Text(String(format: "%.1f×", model.selectedZoomScale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("Zoom magnification for the selected block")
        }
    }
```

Then place `zoomControls` in the control row alongside the existing groups. Find where `cameraControls` and `textControls` are rendered in the body (search `cameraControls` usage in the control row), and add `zoomControls` next to them in the same `HStack`/group, e.g.:

```swift
                zoomControls
```

(Match the surrounding layout — insert it as a sibling of the existing `cameraControls` / `textControls` references, with the same spacing/Divider treatment the neighbors use.)

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: Builds with no errors.

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/Studio/ZoomTimelineLane.swift Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "Add zoom timeline lane and add/delete/scale controls

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: Build the app + manual verification

**Files:** none (verification only).

- [ ] **Step 1: Package and launch the app**

Run:
```bash
scripts/build-app.sh debug && pkill -x CaptureStudio; open dist/CaptureStudio.app
```
Expected: App builds, signs, launches as a menu-bar item (no Dock icon).

- [ ] **Step 2: Verify the lane toggling**

- Open a recording in Studio. Confirm the zoom lane is **hidden** initially.
- Click **Add zoom**. Confirm the zoom lane **appears** with a block at the playhead and it is auto-selected; the scale slider shows (default 2.0×).
- Delete the block. Confirm the lane **hides** again.

- [ ] **Step 3: Verify zoom/pan playback behavior**

- Add a zoom block over a span where the recorded cursor moves and clicks.
- Play across the block. Confirm:
  - Canvas **zooms in** (smoothstep ramp) at block entry and **back out** at exit.
  - Pan **follows the cursor**, and **starts moving slightly before** the cursor reaches a new target (anticipation).
  - When the cursor is **still**, the canvas **holds zoom and the pan freezes** (no drift).
  - **Camera PiP and text overlays do NOT zoom** (stay fixed); the **cursor and click rings DO** scale/move with the screen.
  - Outside the block, the canvas is at normal scale.
- Drag the block edges and body; confirm non-overlap clamping and that playback updates.
- Change the scale slider; confirm the magnification changes.

- [ ] **Step 4: Verify seek/scrub determinism**

- Scrub the playhead back and forth across the block. Confirm the zoom/pan at a given time is **identical** regardless of scrub direction (no drift/jitter from frame ordering).

- [ ] **Step 5: Verify export + persistence**

- Export the clip; confirm the rendered file shows the same auto zoom/pan as the preview.
- Close and reopen the project; confirm the zoom blocks (and any per-block scale) **persist**.
- Confirm an older project (no `zoomBlocks` in `edit.json`) still opens with an empty zoom lane.

- [ ] **Step 6: Final full test run**

Run: `swift test`
Expected: All tests pass.

---

## Self-Review

**Spec coverage:**
- Separate timeline lane → Task 6 (`ZoomTimelineLane`, lane row). ✓
- Lane hidden by default, shown on add → `showsZoomTimeline` (Task 5) + conditional row (Task 6), verified Task 7 Step 2. ✓
- User picks where; no block = no zoom → blocks drive the track; `sample` returns scale 1 outside (Task 3). ✓
- Follow cursor + actions, smooth → `AutoZoomTrack.build` focus + smoothing (Task 3); compositor magnify (Task 4). ✓
- Idle = hold zoom, freeze pan → idle gate (Task 3); test `focusFreezesWhileCursorStill`. ✓
- Anticipation before move/click → `lead` (Task 3); test `focusAnticipatesUpcomingMovement`. ✓
- Per-block scale, global-default override → `ZoomBlock.scale?` (Task 1) + `autoZoomConfig` (Task 5) + slider/reset (Task 5/6); tests `perBlockScaleOverridesGlobalDefault`. ✓
- Non-overlapping blocks → `ZoomTimeline` clamps (Task 2). ✓
- Camera/text not zoomed → only screen/cursor/clicks pass through `magnify` (Task 4); verified Task 7 Step 3. ✓
- Seek-safe (out-of-order frames) → stateless `sample` of a pre-built track (Task 3/4); verified Task 7 Step 4. ✓
- Persistence forward/back compatible → `decodeIfPresent` (Task 1); test `zoomBlocksDefaultEmptyOnOldBundle`. ✓
- Edge: empty cursor samples → centered static zoom (Task 3 test `emptyCursorSamplesCenterFocus`). ✓
- Edge: focus clamped to source → Task 3 test `focusClampedToSourceBounds`. ✓
- Edge: block shorter than ramps → `ramp = min(config.ramp, span/2)` (Task 3). ✓

**Placeholder scan:** No TBD/TODO; all code steps include full code. The only intentionally descriptive step is Task 6 Step 3's placement of `zoomControls` into the existing control row (exact neighbor layout is read at edit time) — the view itself is fully specified.

**Type consistency:** `ZoomBlock` fields/init match across Tasks 1/2/3/5. `ZoomKeyframe` fields (`t/scale/focusX/focusY`) consistent Tasks 3/4. `AutoZoomTrack.build`/`.sample` signatures match between Task 3 definition and Task 4/5 call sites. `OverlayPayload.autoZoom` defined Task 4, set Task 5. Model methods produced in Task 5 match the names called in Task 6 (`addZoomBlock`, `moveZoomBlock[Begin|End]`, `commitZoomEdit`, `selectZoomBlock`, `removeZoomBlock`, `selectedZoomBlockID`, `selectedZoomScale`, `setZoomScale`, `showsZoomTimeline`).

## Execution Handoff

(Choose after the plan is approved — see below.)
