# Auto-Zoom Follow Sensitivity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-block + global "Follow sensitivity" control to auto zoom/pan, so the user can make the pan calmer (ignore small/slow cursor moves) or snappier.

**Architecture:** A single sensitivity value `s ∈ [0,1]` drives the two existing pre-pass knobs via a pure mapping (`AutoZoomTrack.tuning`): `idleSpeed(s) = 200 − 190·s` (deadzone) and `smoothing(s) = 0.30 − 0.25·s` (pan lag). `ZoomBlock.sensitivity: Double?` overrides a global default (`defaultSensitivity = 0.5`, sourced from UserDefaults). Mirrors the existing `scale` override exactly.

**Tech Stack:** Swift 6 (Command Line Tools toolchain), SwiftUI, swift-testing.

## Global Constraints

- Toolchain: **Command Line Tools only — no Xcode.app.** Do NOT bump pinned deps (swift-testing `0.12.0`, KeyboardShortcuts `1.10.0`).
- `swift build`, `swift test` must stay green (155 tests at baseline for this plan).
- Tests use swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`), `@testable import CaptureStudio`.
- Persistence forward/backward compatible: `ZoomBlock.sensitivity` is `Double?` → synthesized `Codable` decodes a missing key as nil (older bundles unaffected).
- Mapping values (exact): `idleSpeed(s) = 200 − 190·s`, `smoothing(s) = 0.30 − 0.25·s`, both with `s` clamped to `[0,1]`. `defaultSensitivity = 0.5`.
- Per-block resolution: `block.sensitivity ?? config.defaultSensitivity`. A per-block `0` is a valid value (fully calm), honored via `??`.
- Global UserDefaults `autoZoomDefaultSensitivity` overrides the default ONLY when in `(0, 1]` (a stored `0.0` = unset → keep built-in 0.5). Same guard style as `autoZoomDefaultScale` (`> 1`).
- Commit messages normal English, end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- UI/model wiring is NOT unit-tested (project convention) — verify by building + running.

---

## File Structure

**Modified files:**
- `Sources/CaptureStudio/ProjectBundle/EditState.swift` — `ZoomBlock.sensitivity`.
- `Tests/CaptureStudioTests/EditStateTests.swift` — round-trip the new field.
- `Sources/CaptureStudio/Studio/AutoZoom.swift` — `AutoZoomConfig` (replace `idleSpeed`/`smoothing` with `defaultSensitivity`), `tuning`, per-block resolution in `build`.
- `Tests/CaptureStudioTests/AutoZoomTrackTests.swift` — `tuning` test, per-block sensitivity test, update the one test that set `cfg.smoothing`.
- `Sources/CaptureStudio/Studio/StudioModel.swift` — `autoZoomConfig` sensitivity, `selectedZoomSensitivity` / `setZoomSensitivity` / `resetZoomSensitivity`.
- `Sources/CaptureStudio/Studio/StudioWindow.swift` — "Follow" slider in `zoomControls`.

---

## Task 1: `ZoomBlock.sensitivity` field + persistence

**Files:**
- Modify: `Sources/CaptureStudio/ProjectBundle/EditState.swift` (the `ZoomBlock` struct)
- Test: `Tests/CaptureStudioTests/EditStateTests.swift`

**Interfaces:**
- Produces: `ZoomBlock` gains `var sensitivity: Double?`; init becomes `init(id: UUID = UUID(), begin: Double, end: Double, scale: Double? = nil, sensitivity: Double? = nil)`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CaptureStudioTests/EditStateTests.swift` (inside its `@Suite`):

```swift
@Test func zoomBlockSensitivityRoundTrip() throws {
    var state = EditState()
    state.zoomBlocks = [
        ZoomBlock(begin: 1, end: 3, scale: 2.0, sensitivity: 0.2),
        ZoomBlock(begin: 4, end: 6, scale: nil, sensitivity: nil),
    ]
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(EditState.self, from: data)
    #expect(decoded.zoomBlocks == state.zoomBlocks)
    #expect(decoded.zoomBlocks[0].sensitivity == 0.2)
    #expect(decoded.zoomBlocks[1].sensitivity == nil)
}

@Test func zoomBlockMissingSensitivityDecodesNil() throws {
    // A zoom block written before `sensitivity` existed (only scale present).
    let json = #"{"zoomBlocks":[{"id":"00000000-0000-0000-0000-000000000000","begin":1,"end":3,"scale":2}]}"#
        .data(using: .utf8)!
    let decoded = try JSONDecoder().decode(EditState.self, from: json)
    #expect(decoded.zoomBlocks.count == 1)
    #expect(decoded.zoomBlocks[0].sensitivity == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EditStateTests`
Expected: FAIL — `extra argument 'sensitivity' in call` (or member not found).

- [ ] **Step 3: Add the field**

In `Sources/CaptureStudio/ProjectBundle/EditState.swift`, in `struct ZoomBlock`, add the stored property after `scale` and the init parameter + assignment. The result must be exactly:

```swift
struct ZoomBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double
    var end: Double
    var scale: Double?
    /// How aggressively auto-zoom pans toward the cursor (0 = calm / ignore
    /// small moves, 1 = snappy). nil = use the global default
    /// (`autoZoomDefaultSensitivity`). Mirrors `scale`'s override semantics.
    var sensitivity: Double?

    init(id: UUID = UUID(), begin: Double, end: Double, scale: Double? = nil,
         sensitivity: Double? = nil) {
        self.id = id
        self.begin = begin
        self.end = end
        self.scale = scale
        self.sensitivity = sensitivity
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EditStateTests`
Expected: PASS (including the two new tests). The existing `zoomBlocksRoundTrip` still passes (it omits `sensitivity`, which defaults nil).

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/ProjectBundle/EditState.swift Tests/CaptureStudioTests/EditStateTests.swift
git commit -m "Add ZoomBlock.sensitivity override field

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Sensitivity mapping in `AutoZoom`

**Files:**
- Modify: `Sources/CaptureStudio/Studio/AutoZoom.swift`
- Test: `Tests/CaptureStudioTests/AutoZoomTrackTests.swift`

**Interfaces:**
- Consumes: `ZoomBlock.sensitivity` (Task 1).
- Produces:
  - `AutoZoomConfig` no longer has `idleSpeed` / `smoothing`; it has `var defaultSensitivity: Double = 0.5` (other fields unchanged: `defaultScale`, `lead`, `ramp`, `step`).
  - `static func tuning(_ s: Double) -> (idleSpeed: Double, smoothing: Double)` on `AutoZoomTrack`.
  - `AutoZoomTrack.build` resolves per-block sensitivity → per-block idleSpeed/smoothing.

- [ ] **Step 1: Write the failing tests**

In `Tests/CaptureStudioTests/AutoZoomTrackTests.swift`:

(a) Replace the body of `focusAnticipatesUpcomingMovement` (it currently sets `cfg.smoothing = 0.05`, a field that is being removed). New version uses max sensitivity (which maps to smoothing 0.05):

```swift
    @Test func focusAnticipatesUpcomingMovement() {
        // Lead should pull focus toward the upcoming x=800 before t=2 (when the
        // cursor is still physically at x=200). Max sensitivity = snappy + tiny
        // deadzone, so the drift is clearly visible.
        var cfg = AutoZoomConfig(); cfg.lead = 0.4; cfg.defaultSensitivity = 1.0
        let blocks = [ZoomBlock(begin: 0, end: 4, scale: 2)]
        let track = AutoZoomTrack.build(blocks: blocks, cursorSamples: movingCursor(),
                                        sourceSize: source, config: cfg)
        let focusJustBeforeMove = AutoZoomTrack.sample(at: 1.95, track: track).focus.x
        let focusAtStart = AutoZoomTrack.sample(at: 0.5, track: track).focus.x
        #expect(focusJustBeforeMove > focusAtStart + 1)   // already drifting toward 800
    }
```

(b) Add a `tuning` test and a per-block-sensitivity behavior test (append inside the suite):

```swift
    @Test func tuningEndpointsClampAndMonotonic() {
        let lo = AutoZoomTrack.tuning(0)
        let hi = AutoZoomTrack.tuning(1)
        #expect(abs(lo.idleSpeed - 200) < 1e-9)
        #expect(abs(lo.smoothing - 0.30) < 1e-9)
        #expect(abs(hi.idleSpeed - 10) < 1e-9)
        #expect(abs(hi.smoothing - 0.05) < 1e-9)
        // Higher sensitivity → smaller deadzone and less lag.
        #expect(hi.idleSpeed < lo.idleSpeed)
        #expect(hi.smoothing < lo.smoothing)
        // Clamps out-of-range input.
        #expect(AutoZoomTrack.tuning(-1).idleSpeed == 200)
        #expect(AutoZoomTrack.tuning(2).idleSpeed == 10)
    }

    // Cursor drifts slowly: 200 → 260 over 4s ≈ 15 px/s.
    private func slowDriftCursor() -> [CursorSample] {
        var s: [CursorSample] = []
        var t = 0.0
        while t <= 5.0 {
            let x = 200 + min(60, t * 15)
            s.append(CursorSample(t: t, p: CGPoint(x: x, y: 500), cursor: "arrow"))
            t += 1.0 / 60.0
        }
        return s
    }

    @Test func lowSensitivityIgnoresSlowMoveHighFollows() {
        let cursor = slowDriftCursor()
        // s=0 → deadzone 200 px/s, well above the 15 px/s drift → frozen.
        let low = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 0)],
                                      cursorSamples: cursor, sourceSize: source)
        // s=1 → deadzone 10 px/s, below the drift → follows.
        let high = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 1)],
                                       cursorSamples: cursor, sourceSize: source)
        let lowFocus = AutoZoomTrack.sample(at: 3.0, track: low).focus.x
        let highFocus = AutoZoomTrack.sample(at: 3.0, track: high).focus.x
        #expect(lowFocus < 215)               // stayed near start (ignored slow drift)
        #expect(highFocus > lowFocus + 10)    // followed the drift
    }

    @Test func perBlockSensitivityOverridesDefault() {
        let cursor = slowDriftCursor()
        var cfg = AutoZoomConfig(); cfg.defaultSensitivity = 0   // global = calm
        // Per-block override to snappy should follow despite the calm default.
        let track = AutoZoomTrack.build(blocks: [ZoomBlock(begin: 0, end: 4, scale: 2, sensitivity: 1)],
                                        cursorSamples: cursor, sourceSize: source, config: cfg)
        #expect(AutoZoomTrack.sample(at: 3.0, track: track).focus.x > 215)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AutoZoomTrackTests`
Expected: FAIL — `value of type 'AutoZoomConfig' has no member 'defaultSensitivity'` / `type 'AutoZoomTrack' has no member 'tuning'`.

- [ ] **Step 3: Update `AutoZoomConfig`**

In `Sources/CaptureStudio/Studio/AutoZoom.swift`, replace the `idleSpeed` and `smoothing` fields with `defaultSensitivity`. The struct becomes:

```swift
struct AutoZoomConfig {
    var defaultScale: Double = 2.0
    /// Anticipation: focus targets the cursor position this many seconds ahead.
    var lead: Double = 0.4
    /// Zoom-in / zoom-out ramp duration (each end of a block).
    var ramp: Double = 0.4
    /// How aggressively the pan follows the cursor, 0…1 (0 = calm / big
    /// deadzone + laggy, 1 = snappy / tiny deadzone + responsive). Resolved to
    /// the low-level deadzone + smoothing via `AutoZoomTrack.tuning`. Overridden
    /// per block by `ZoomBlock.sensitivity`, or globally by
    /// `autoZoomDefaultSensitivity`.
    var defaultSensitivity: Double = 0.5
    /// Keyframe sampling step (seconds).
    var step: Double = 1.0 / 60.0
}
```

- [ ] **Step 4: Add `tuning` and use it per-block in `build`**

In `enum AutoZoomTrack`, add the `tuning` helper (place it in the `// MARK: - Helpers` section, e.g. just above `cursorPoint`):

```swift
    /// Map a 0…1 sensitivity to the low-level pan knobs. Low sensitivity = large
    /// deadzone (ignore small/slow moves) + heavy smoothing (laggy); high =
    /// small deadzone + light smoothing (snappy).
    static func tuning(_ s: Double) -> (idleSpeed: Double, smoothing: Double) {
        let c = min(max(s, 0), 1)
        return (idleSpeed: 200 - 190 * c, smoothing: 0.30 - 0.25 * c)
    }
```

Then change `build` so the smoothing/idleSpeed are resolved per block. Remove the file-scope `alpha` line (it referenced `config.smoothing`) and compute per block. The `build` function body becomes:

```swift
    static func build(blocks: [ZoomBlock], cursorSamples: [CursorSample],
                      sourceSize: CGSize,
                      config: AutoZoomConfig = AutoZoomConfig()) -> [ZoomKeyframe] {
        guard !blocks.isEmpty else { return [] }
        let center = CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        var out: [ZoomKeyframe] = []

        for block in blocks.sorted(by: { $0.begin < $1.begin }) {
            let span = block.end - block.begin
            guard span > 0 else { continue }
            let target = max(1, block.scale ?? config.defaultScale)
            let ramp = min(config.ramp, span / 2)
            // Per-block sensitivity → deadzone + smoothing.
            let (idleSpeed, smoothing) = tuning(block.sensitivity ?? config.defaultSensitivity)
            let alpha = 1 - exp(-config.step / max(smoothing, 1e-4))

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
                let speed = cursorSpeed(at: aheadT, in: cursorSamples, dt: config.step)
                let desired = speed < idleSpeed ? lastTarget : raw
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
```

(Only two things changed vs the current body: the file-scope `alpha` line is gone, and the per-block `let (idleSpeed, smoothing) = ...` + `let alpha = ...` lines were added inside the loop; the idle gate now reads the local `idleSpeed`.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter AutoZoomTrackTests`
Expected: PASS (all existing + new). Then run the full suite once:

Run: `swift test`
Expected: all green (no other file references `AutoZoomConfig.idleSpeed`/`.smoothing` — confirm with `grep -rn "\.idleSpeed\|\.smoothing" Sources Tests` returns only the new `tuning` internals / none).

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/Studio/AutoZoom.swift Tests/CaptureStudioTests/AutoZoomTrackTests.swift
git commit -m "Drive auto-zoom deadzone + smoothing from a 0..1 sensitivity

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: StudioModel sensitivity config + ops

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (`autoZoomConfig` ~line 112; zoom ops near `resetZoomScale` ~line 784)

**Interfaces:**
- Consumes: `AutoZoomConfig.defaultSensitivity` (Task 2), `ZoomBlock.sensitivity` (Task 1).
- Produces: `var selectedZoomSensitivity: Double`, `func setZoomSensitivity(_:)`, `func resetZoomSensitivity()`. `autoZoomConfig` now also sets `defaultSensitivity` from UserDefaults.

Model glue — not unit-tested. Verify by building + full suite.

- [ ] **Step 1: Extend `autoZoomConfig`**

In `StudioModel.swift`, update `autoZoomConfig` (currently lines 112-117) to also read the sensitivity default:

```swift
    /// Per-project defaults for new/unset blocks (global config).
    var autoZoomConfig: AutoZoomConfig {
        var c = AutoZoomConfig()
        let v = UserDefaults.standard.double(forKey: "autoZoomDefaultScale")
        if v > 1 { c.defaultScale = v }
        let s = UserDefaults.standard.double(forKey: "autoZoomDefaultSensitivity")
        if s > 0 && s <= 1 { c.defaultSensitivity = s }
        return c
    }
```

- [ ] **Step 2: Add the sensitivity ops**

In `StudioModel.swift`, immediately after `resetZoomScale()` (after its closing brace ~line 784, before the `setZoomBlocks` doc comment), add:

```swift
    /// Effective follow-sensitivity of the selected block (its override, else
    /// the global default).
    var selectedZoomSensitivity: Double {
        guard let id = selectedZoomBlockID,
              let b = zoomBlocks.first(where: { $0.id == id }) else {
            return autoZoomConfig.defaultSensitivity
        }
        return b.sensitivity ?? autoZoomConfig.defaultSensitivity
    }

    /// Set the selected block's sensitivity override (live; persist via
    /// commitZoomEdit).
    func setZoomSensitivity(_ v: Double) {
        guard let id = selectedZoomBlockID,
              let i = zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        zoomBlocks[i].sensitivity = min(max(0, v), 1)
        applyVideoComposition()
    }

    /// Clear the override so the block follows the global default again.
    func resetZoomSensitivity() {
        guard let id = selectedZoomBlockID,
              let i = zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        zoomBlocks[i].sensitivity = nil
        applyVideoComposition()
        saveEdit()
    }
```

- [ ] **Step 3: Build + full suite**

Run: `swift build`
Expected: compiles clean.

Run: `swift test`
Expected: 155+ tests green (no regressions; this task adds no tests).

- [ ] **Step 4: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift
git commit -m "StudioModel: per-block + global auto-zoom sensitivity ops

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: "Follow" slider in zoomControls + manual verify

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` (`zoomControls`)

**Interfaces:**
- Consumes: `selectedZoomSensitivity` / `setZoomSensitivity` / `commitZoomEdit` (Task 3).

UI glue — not unit-tested. Verify by building + running.

- [ ] **Step 1: Add the slider**

In `StudioWindow.swift`, inside `zoomControls`, within the existing `if model.selectedZoomBlockID != nil { ... }` block, ADD a second `HStack` right after the existing scale `HStack(...).help("Zoom magnification for the selected block")`. The `if` block becomes:

```swift
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

            HStack(spacing: 4) {
                Image(systemName: "hand.draw")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { model.selectedZoomSensitivity },
                                   set: { model.setZoomSensitivity($0) }),
                    in: 0...1,
                    onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
                )
                .frame(width: 90)
                Text("\(Int((model.selectedZoomSensitivity * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("Follow sensitivity — how aggressively the zoom pans toward the cursor (low = calm, high = snappy)")
        }
```

(The scale `HStack` is unchanged; only the second `HStack` is new.)

- [ ] **Step 2: Build + full suite**

Run: `swift build`
Expected: compiles clean.

Run: `swift test`
Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "Add Follow sensitivity slider to zoom controls

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 4: Package + manual verify**

Run:
```bash
scripts/build-app.sh debug && pkill -x CaptureStudio; open dist/CaptureStudio.app
```

Then in Studio, with a zoom block selected over a span where the cursor makes small/jittery moves:
- Confirm a "Follow" slider appears next to the magnification slider.
- Slide it DOWN: playback pan should ignore small/slow moves and feel calmer/laggier.
- Slide it UP: pan should track the cursor snappily, including small moves.
- Confirm the default (no change) feels calmer than before the feature.
- Confirm the per-block value persists across close/reopen.

---

## Self-Review

**Spec coverage:**
- One sensitivity slider, low=calm/high=snappy → `tuning` mapping (Task 2) + slider (Task 4). ✓
- Maps to deadzone + smoothing → `tuning` returns both; `build` uses both (Task 2). ✓
- Per-block override + global default → `ZoomBlock.sensitivity` (Task 1), `defaultSensitivity` + UserDefaults (Tasks 2-3). ✓
- Replace raw idleSpeed/smoothing fields (single source) → Task 2 Step 3. ✓
- Default 0.5, calmer than shipped → `defaultSensitivity = 0.5` (Task 2). ✓
- Backward-compatible persistence → optional field, round-trip + missing-key tests (Task 1). ✓
- Per-block `0` honored via `??`; global UserDefaults guarded to `(0,1]` → Tasks 2-3. ✓
- Tests: tuning endpoints/clamp/monotonic, per-block override, low-vs-high follow, updated anticipation test → Task 2. ✓

**Placeholder scan:** No TBD/TODO; every code step has full code.

**Type consistency:** `ZoomBlock.sensitivity: Double?` and the 5-arg init are used consistently in Tasks 1-4. `AutoZoomConfig.defaultSensitivity` defined Task 2, consumed Task 3. `AutoZoomTrack.tuning(_:) -> (idleSpeed, smoothing)` defined + used Task 2. Model methods produced in Task 3 (`selectedZoomSensitivity`, `setZoomSensitivity`, `resetZoomSensitivity`) match the slider call sites in Task 4.

## Execution Handoff

User pre-selected: **Subagent-Driven** (same flow as the prior feature). Proceed with superpowers:subagent-driven-development.
