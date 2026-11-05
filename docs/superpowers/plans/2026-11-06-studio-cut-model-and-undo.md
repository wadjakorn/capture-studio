# Studio: export pause, unified split-&-cut trim, undo/redo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the three `todo` tickets on the board (project `DOgiocMzhN_l`): pause preview when export starts (`gcznZn00d2qD`), replace destructive trim with split-&-cut + hover preview (`4nkhM2OIkGko`, "CS-0003"), and multi-level undo/redo (`NITZEw6B_gX1`, "CS-0004").

**Architecture:** Part A is a two-line guard. Part B deletes the committed-trim subsystem (`TrimTimeline`, `committedTrimStart/End`, `trimIn/trimOut`, `trimUndo`) and expresses trimming as hidden head/tail segments through one new pure primitive, `TimelineSegments.cut(range:)`; legacy bundles are migrated on load into that model; a `CutPreview` value on `StudioModel` drives a hover overlay on the timeline. Part C adds a generic `EditHistory<EditState>` fed from the single `saveEdit()` funnel (the pre-save `EditState` is the undo snapshot, so drags coalesce for free), and an `applyEdit(_:)` that load and undo/redo share.

**Tech Stack:** Swift 6 / SwiftUI / AVFoundation, swift-testing 0.12.0, Command Line Tools only.

**Spec:** the three ticket descriptions (fetch with `PM_API=http://wadjakorn-bmax:3000 pm task list --project DOgiocMzhN_l --status todo --json`). Copied decisions: trims are non-destructive and baked at export; no auto-resume after export; history is in-memory per Studio session, cap 100; playhead/seek/play/timeline zoom/selection/export are not undoable.

## Global Constraints

- CLT-only toolchain: do not bump swift-testing (`0.12.0`) or KeyboardShortcuts (`1.10.0`); no `#Preview`.
- `swift build` and `swift test` must stay green after every task.
- Board hygiene: before starting a Part, `pm task move --id <id> --status doing`; after its final task, `--status completed` (one legal edge at a time, `PM_API=http://wadjakorn-bmax:3000`).
- **Never commit or push without explicit user confirmation** (CLAUDE.md). Commit steps below mean: stage, show the diff summary, ask, then commit with the message given, ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- `EditState` on-disk compatibility: old keys (`trimIn`, `trimOut`, `committedTrimStart`, `committedTrimEnd`) stay decodable forever; `schemaVersion` stays `1`.
- Architecture invariants in CLAUDE.md (cursor from `events.jsonl`, host-clock sync, chrome exclusion) are untouched by this plan.
- Order: Part A → Part B → Part C. Part C depends on Part B (one cut model).

## Review Focus

Inputs the tickets imply but no acceptance line tests; each has a pinned test in the owning task:

1. **Trim End at the playhead while the playhead sits inside the tail** — the playhead must land on the last visible frame, not at `duration` (inside the cut). → Task B4 `trimEndParksPlayheadOnLastVisibleFrame`.
2. **Trim Start / Trim End within `splitMinWidth` of an existing boundary** — must snap to that boundary instead of silently no-opping. → Task B1 `cutSnapsToNearbyBoundary`.
3. **Legacy bundle whose `committedTrimEnd` exceeds the master length** (master re-encoded or clamped) — migration must clamp, never produce a segment past `duration`. → Task B2 `migrationClampsWindowToMaster`.
4. **Undo of a crop-aspect / first-text-block / camera-style change on a paused player** — the custom compositor does not repaint a paused frame on `videoComposition` reassignment, and AVPlayer caches presentation size. Undo must swap the player item (`rebuildPreview()`), not just reassign the composition. → Task C3 (unconditional `rebuildPreview()`), manual check in C4.
5. **⌘Z while a caption text field is first responder** — must reach `NSTextView`'s own undo, not the editor history. → Task C4 (key catcher skips when `firstResponder is NSTextView`; fallback documented).
6. **Playhead clock vs. trailing cut** — the periodic time observer maps collapsed time back with `TimelineCut.unmap`, which resolves the collapsed end onto `duration` (inside a trailing cut). `currentTime` must be clamped to `visibleBounds.end`. → Task B3 observer bullet + B4 `trimEndParksPlayheadOnLastVisibleFrame` (the unit test alone is not sufficient evidence; manual check in B6).

---

## Part A — pause preview when export starts (`gcznZn00d2qD`)

### Task 1 (A1): pause on export, guard togglePlay

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (`export(preset:to:)` ~L2907, `togglePlay()` ~L2682)
- Test: `Tests/CaptureStudioTests/ExportLockTests.swift`

**Interfaces:**
- Produces: no new API. `togglePlay()` becomes a no-op while `isExporting`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func togglePlayIsNoOpWhileExporting() {
    let m = makeModel()
    m.beginExportLockForTests()
    m.togglePlay()
    #expect(!m.isPlaying)
}
```
(The test model has no `player`, so this only pins "no crash + still not playing"; the real behaviour is covered by the manual check in Step 5.)

- [ ] **Step 2: Run it** — `swift test --filter ExportLockTests` → passes already (guard missing but `player` nil). Keep as a regression pin.

- [ ] **Step 3: Implement**
  - In `togglePlay()`: first line `guard !isExporting, let player else { return }`.
  - In `export(preset:to:)`: immediately before `exportState = .exporting(0)` add `player?.pause()`. Do **not** touch `cancelExport`, `.done`, `.failed` paths (no auto-resume).

- [ ] **Step 4: Verify** — `swift build && swift test` green.

- [ ] **Step 5: Manual check** — `scripts/build-app.sh debug; pkill -x CaptureStudio; open dist/CaptureStudio.app`: Play → Export: video+audio stop at once, playhead stays; Space does nothing during export; after Stop/success, Play works and resumes from the parked playhead.

- [ ] **Step 6: Commit (after confirmation)** — `fix(studio): pause preview playback when an export starts`

---

## Part B — trim = split & cut, hover preview, legacy migration (`4nkhM2OIkGko`)

File map for Part B:

| File | Change |
|---|---|
| `Studio/TimelineSegments.swift` | add `cut(_:range:minWidth:)`, `visibleBounds(_:duration:)`, `CutAction`, `CutPreview`, `preview(for:segments:at:duration:)` |
| `Studio/LegacyTrimMigration.swift` (new) | `migrate(_ edit:, masterDuration:) -> EditState` |
| `Studio/TrimTimeline.swift` | **delete** (+ `Tests/.../TrimTimelineTests.swift`, the `TrimTimeline.apply` test in `ShapeTimelineTests.swift:~205`) |
| `ProjectBundle/EditState.swift` | keep the four legacy fields decodable, mark `// legacy, migrated on load`, never set by the app |
| `Studio/StudioModel.swift` | remove committed-trim load path, `trimIn/trimOut`, `TrimUndoState`, `setTrimIn/Out`, `resetTrim`, `restoreTrimUndo`, `applyTrim`, `canApplyTrim`; add `trimStartAtPlayhead/EndAtPlayhead`, `can…`, `hoverPreview`, `setHoverPreview`; fix `togglePlay`, export range, `loadOverlayData` |
| `Studio/StudioTransportBar.swift` | new `trimControls`, single clear button, `.onHover` wiring |
| `Studio/StudioWindow.swift` | display lane: drop trimIn/trimOut tint, draw `hoverPreview`; lane stack: dim overlay |
| `Studio/CutPreviewOverlay.swift` (new) | the two overlay views |
| `Tests/.../TimelineSegmentsTests.swift`, `Tests/.../LegacyTrimMigrationTests.swift` (new), `Tests/.../ExportLockTests.swift`, `Tests/.../EditStateTests.swift` | tests |

### Task 2 (B1): `TimelineSegments.cut(range:)` + `visibleBounds`

**Files:**
- Modify: `Sources/CaptureStudio/Studio/TimelineSegments.swift`
- Test: `Tests/CaptureStudioTests/TimelineSegmentsTests.swift`

**Interfaces (Produces):**
```swift
extension TimelineSegments {
    /// Hide `[range.lowerBound, range.upperBound)`: split at each bound that lies
    /// strictly inside a segment (a bound within `minWidth` of an existing
    /// boundary snaps to that boundary instead of splitting), then mark every
    /// segment fully inside the (snapped) range hidden. Returns the input
    /// unchanged when the range is empty after snapping or when no visible
    /// segment would remain.
    static func cut(_ segments: [TimelineSegment], range: Range<Double>,
                    minWidth: Double = splitMinWidth) -> [TimelineSegment]
    /// First and last visible instants: `(start, end)` with `start` = end of a
    /// leading hidden run (else 0), `end` = start of a trailing hidden run
    /// (else `duration`).
    static func visibleBounds(_ segments: [TimelineSegment], duration: Double) -> (start: Double, end: Double)
}
```

- [ ] **Step 1: Failing tests** (all on `TimelineSegments.full(duration: 10)` unless noted)

```swift
@Test func cutHeadProducesHiddenLeadingSegment() {
    let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<3)
    #expect(s.count == 2); #expect(s[0].hidden && s[0].end == 3); #expect(!s[1].hidden)
}
@Test func cutTailProducesHiddenTrailingSegment() {
    let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 7..<10)
    #expect(s.count == 2); #expect(!s[0].hidden); #expect(s[1].hidden && s[1].start == 7)
}
@Test func cutMiddleSplitsTwice() {
    let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 2..<5)
    #expect(s.map(\.hidden) == [false, true, false]); #expect(s[1].start == 2 && s[1].end == 5)
}
@Test func cutSnapsToNearbyBoundary() {
    var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
    s = TimelineSegments.cut(s, range: 0..<4.02)             // within splitMinWidth of 4
    #expect(s.count == 2); #expect(s[0].hidden && s[0].end == 4)
}
@Test func cutRefusesToHideEverything() {
    let full = TimelineSegments.full(duration: 10)
    #expect(TimelineSegments.cut(full, range: 0..<10) == full)
}
@Test func cutEmptyRangeIsNoOp() {
    let full = TimelineSegments.full(duration: 10)
    #expect(TimelineSegments.cut(full, range: 3..<3.01) == full)
}
@Test func cutPreservesExistingHiddenInsideRange() {
    var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 2).segments
    s = TimelineSegments.setHidden(s, id: s[0].id, true)     // [0,2) hidden
    s = TimelineSegments.cut(s, range: 0..<5)
    #expect(TimelineSegments.cutRanges(s) == [0..<5])
}
@Test func visibleBoundsSkipLeadingAndTrailingCuts() {
    var s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<2)
    s = TimelineSegments.cut(s, range: 8..<10)
    let b = TimelineSegments.visibleBounds(s, duration: 10)
    #expect(b.start == 2 && b.end == 8)
    #expect(TimelineSegments.visibleBounds([], duration: 10) == (0, 10))
}
```

- [ ] **Step 2: Run** — `swift test --filter TimelineSegmentsTests` → FAIL "no member 'cut'".
- [ ] **Step 3: Implement** both functions. **Equality trap:** `TimelineSegments.full(duration:)` mints a fresh `UUID` on every call and `TimelineSegment` is `Equatable` including `id`, so `cut(full(10), …) == full(10)` is *never* true. Every "unchanged?" comparison in this plan must evaluate the input list once into a `let` and compare against that same instance (the tests above do this via `let full`). Snap rule: for each bound `b`, if some segment boundary `x` has `|x - b| < minWidth` use `x`; else `split(at: b)`. Then `hidden = true` for segments with `start >= lo - 1e-9 && end <= hi + 1e-9`; apply the "at least one visible" rule once on the result (compare `visibleCount`), returning the input if violated.
- [ ] **Step 4: Run** — PASS. `swift test` all green.
- [ ] **Step 5: Commit (after confirmation)** — `feat(studio): TimelineSegments.cut(range:) and visibleBounds`

### Task 3 (B2): `LegacyTrimMigration`

**Files:**
- Create: `Sources/CaptureStudio/Studio/LegacyTrimMigration.swift`
- Modify: `Sources/CaptureStudio/ProjectBundle/EditState.swift:690-704` (doc comments only: mark the four fields legacy)
- Test: `Tests/CaptureStudioTests/LegacyTrimMigrationTests.swift` (new)

**Interfaces (Produces):**
```swift
/// Pure. Lift an `EditState` saved against the committed-trim window onto the
/// full master timeline: blocks/subtitle offset shift by `committedTrimStart`;
/// the window edges and the live In/Out markers become hidden segments.
/// Output has committedTrimStart == 0, committedTrimEnd == nil, trimIn == 0,
/// trimOut == nil. Idempotent: a state with no legacy trim is returned as is.
enum LegacyTrimMigration {
    static func migrate(_ edit: EditState, masterDuration: Double) -> EditState
}
```

Algorithm (the part the signature does not determine):
1. `cs = clamp(edit.committedTrimStart, 0, master)`, `ce = clamp(edit.committedTrimEnd ?? master, cs, master)`. If `cs == 0 && ce == master && trimIn == 0 && trimOut == nil` → return `edit`.
2. Shift every block list's `begin/end` by `+cs` (camera, layout, zoom, text, shape); `subtitles?.offset += cs`.
3. `segs = edit.segments.isEmpty ? full(master) : normalized(segments shifted by +cs, duration: master)`.
4. `segs = cut(segs, range: 0..<cs)` if `cs > 0`; `segs = cut(segs, range: ce..<master)` if `ce < master`.
5. Markers (replicates the legacy load rule at `StudioModel.swift:587`: `if trimOut <= trimIn` the markers are ignored): `tin = clamp(cs + edit.trimIn, cs, ce)`, `tout = clamp(cs + (edit.trimOut ?? (ce - cs)), cs, ce)`; if `tout <= tin` skip both; else if `tin > cs` → `cut(range: cs..<tin)`; if `tout < ce` → `cut(range: tout..<ce)`.
6. Zero the four legacy fields; set `segments = segs` (if the only segment is a single visible one, store `[]`).

- [ ] **Step 1: Failing tests**

```swift
@Test func noLegacyTrimIsIdentity()                 // EditState() → equal
@Test func committedWindowBecomesHeadAndTailCuts()  // cs 2, ce 8, master 10 → cutRanges == [0..<2, 8..<10]
@Test func blocksAreRebasedToMasterTime()           // cam(1,3) with cs 2 → cam(3,5); subtitles.offset 0 → 2
@Test func existingSegmentsShiftWithTheWindow()     // segments [0,3)(hidden),[3,6) in window cs 2 → hidden 2..<5 in master
@Test func liveMarkersBecomeCuts()                  // cs 0, trimIn 1.5, trimOut 8.25 on master 10 → [0..<1.5, 8.25..<10]
@Test func migrationClampsWindowToMaster()          // cs 2, ce 50, master 10 → cutRanges == [0..<2]; no segment end > 10
@Test func invertedMarkersAreIgnored()               // trimIn 8, trimOut 2 → no cuts from markers (legacy load rule)
@Test func legacyFieldsAreZeroedAfterMigration()    // committedTrimStart 0, committedTrimEnd nil, trimIn 0, trimOut nil
```
Build camera blocks with the same helpers `TrimTimelineTests.swift` uses today (copy `cam(_:_:)` before deleting that file).

- [ ] **Step 2: Run** — FAIL (type missing). **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: EditState comments** — on the four legacy fields write: `/// Legacy (pre split-&-cut trim). Decoded for migration by LegacyTrimMigration; the app never sets these anymore.` Keep the `EditStateTests` that decode them (they still pass). Add to `EditStateTests`: `savedEditWritesLegacyTrimDefaults` — encode `EditState(segments: [...])`, decode, expect `trimIn == 0`, `trimOut == nil`, `committedTrimStart == 0`, `committedTrimEnd == nil` (pins "stop writing them / write defaults").
- [ ] **Step 6: Commit (after confirmation)** — `feat(studio): migrate legacy committed trim and In/Out markers into hidden segments`

### Task 4 (B3): remove the committed-trim subsystem from `StudioModel`

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift`
- Delete: `Sources/CaptureStudio/Studio/TrimTimeline.swift`, `Tests/CaptureStudioTests/TrimTimelineTests.swift`
- Modify: `Tests/CaptureStudioTests/ShapeTimelineTests.swift` (remove the `TrimTimeline.apply` test ~L205-215), `Tests/CaptureStudioTests/ExportLockTests.swift` (`mutatorsNoOpWhileExporting` uses `setTrimIn` — replace in Task B4)

**Interfaces:**
- Consumes: `LegacyTrimMigration.migrate`, `TimelineSegments.visibleBounds`.
- Produces: `StudioModel.visibleBounds: (start: Double, end: Double)` computed property.

- [ ] **Step 1: Delete** `trimIn`, `trimOut`, `committedTrimStart`, `committedTrimEnd`, `trimUndo`, `TrimUndoState`, `canApplyTrim`, `setTrimIn`, `setTrimOut`, `resetTrim`, `restoreTrimUndo`, `applyTrim`. Build; fix each compile error as follows:
  - **load (~L540-590):** drop the `removeTimeRange` block; `let edit = LegacyTrimMigration.migrate(bundle.loadEdit(), masterDuration: built.composition.duration.seconds)`; drop the `trimIn/trimOut` assignments.
  - **`loadOverlayData` (~L797):** `head = 0` → remove the rebase; keep the `t <= dur` filter.
  - **`currentEdit()` (~L2855):** drop the four arguments (defaults apply).
  - **`togglePlay()`:** `let (start, end) = visibleBounds; if currentTime >= end - 0.05 { seek(to: start) }`.
  - **periodic time observer (~L649-660):** `TimelineCut.unmap` resolves the collapsed end onto `duration`, i.e. inside a trailing cut. Clamp: `self.currentTime = min(unmapped, self.visibleBounds.end)`. (Without this, Trim End parks the playhead at `duration` in the real app even though the B4 unit test passes.)
  - **`export()`:** no cuts → `range = CMTimeRange(start: .zero, end: ts(duration))`; cuts → `range = CMTimeRange(start: .zero, end: ts(TimelineCut.remainingDuration(duration, cuts: cuts)))`.
  - **after `rebuildPreview()` in load:** `seek(to: visibleBounds.start)` so a bundle with a leading cut opens on its first visible frame.
  - Add `var visibleBounds: (start: Double, end: Double) { TimelineSegments.visibleBounds(segments, duration: duration) }`.
- [ ] **Step 2: Transport/window in the same commit** — in `StudioTransportBar` delete `trimControls` and its `Divider` (B5 adds the new controls); in `StudioWindow.timeline` replace the kept-region rect's width with the full `width` and offset `0`. No temporary `EmptyView()` stubs.
- [ ] **Step 3:** `swift build && swift test` green (after removing the `TrimTimeline` test files and `setTrimIn` usage — temporarily swap it for `m.resetSegments()` and assert `segments` unchanged).
- [ ] **Step 4: Commit (after confirmation)** — `refactor(studio): drop destructive committed trim; cuts are the only edit model`

### Task 5 (B4): trim-at-playhead actions + playhead settling

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (Split & cut section ~L1347-1435)
- Test: `Tests/CaptureStudioTests/ExportLockTests.swift`, new `Tests/CaptureStudioTests/StudioModelCutTests.swift`

**Interfaces (Produces):**
```swift
var canTrimStartAtPlayhead: Bool   // !isExporting && { let s = effectiveSegments; return cut(s, range: 0..<t) != s }()
var canTrimEndAtPlayhead: Bool     // same with t..<duration — see the B1 equality trap: never call effectiveSegments twice
func trimStartAtPlayhead()         // let s = effectiveSegments; let c = cut(s, …); guard c != s; setSegments(c); settlePlayhead()
func trimEndAtPlayhead()
#if DEBUG
func loadForTests(duration: Double, segments: [TimelineSegment] = [])  // sets duration/segments/currentTime without AVFoundation
#endif
```
`settlePlayhead()` (private): if `hiddenRange(containing: currentTime)` is `r` → `seek(to: r.upperBound >= duration - 1e-6 ? r.lowerBound : r.upperBound)`. Replace the inline hop in `hideSegment` with this call. `seek` with `player == nil` must still update `currentTime` (it does today).

- [ ] **Step 1: Failing tests**

```swift
@MainActor struct StudioModelCutTests {
    func model() -> StudioModel { let m = StudioModel(bundleURL: URL(fileURLWithPath: "/tmp/cut-test.capturestudio")); m.loadForTests(duration: 10); return m }
    @Test func trimStartHidesHead() { let m = model(); m.seek(to: 3); m.trimStartAtPlayhead()
        #expect(TimelineSegments.cutRanges(m.segments) == [0..<3]); #expect(m.currentTime == 3) }
    @Test func trimEndParksPlayheadOnLastVisibleFrame() { let m = model(); m.seek(to: 7); m.trimEndAtPlayhead()
        #expect(TimelineSegments.cutRanges(m.segments) == [7..<10]); #expect(m.currentTime == 7) }
    @Test func trimStartAtZeroIsDisabled() { let m = model(); m.seek(to: 0); #expect(!m.canTrimStartAtPlayhead) }
    @Test func trimsAreNoOpWhileExporting() { let m = model(); m.seek(to: 3); m.beginExportLockForTests(); m.trimStartAtPlayhead(); #expect(m.segments.isEmpty) }
    @Test func visibleBoundsFollowTrims() { let m = model(); m.seek(to: 2); m.trimStartAtPlayhead(); m.seek(to: 8); m.trimEndAtPlayhead()
        #expect(m.visibleBounds == (2, 8)) }
}
```
In `ExportLockTests.mutatorsNoOpWhileExporting` use `trimStartAtPlayhead()` on a `loadForTests(duration: 10)` model seeked to 3.

- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** (note `saveEdit()` inside `setSegments` writes to `/tmp/...`; `try?` swallows the missing-bundle error — acceptable, same as `ExportLockTests` today). **Step 4: Run** — PASS, suite green.
- [ ] **Step 5: Commit (after confirmation)** — `feat(studio): Trim Start / Trim End as split-and-cut at the playhead`

### Task 6 (B5): hover preview model + transport bar

**Files:**
- Modify: `Sources/CaptureStudio/Studio/TimelineSegments.swift` (append `CutAction`, `CutPreview`, `preview(for:…)`)
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (`@Published var hoverAction: CutAction?`, computed `var hoverPreview: CutPreview?`)
- Modify: `Sources/CaptureStudio/Studio/StudioTransportBar.swift`
- Test: `Tests/CaptureStudioTests/TimelineSegmentsTests.swift`

**Interfaces (Produces):**
```swift
enum CutAction: Equatable { case cutSegment, restoreSegment, trimStart, trimEnd, clearAll }
struct CutPreview: Equatable {
    enum Kind { case cut, restore }
    var ranges: [Range<Double>]
    var kind: Kind
    /// A split that the action would create (not yet a boundary) — drawn as a marker.
    var pendingSplitAt: Double?
}
extension TimelineSegments {
    /// nil when the action would change nothing.
    static func preview(for action: CutAction, segments: [TimelineSegment],
                        at t: Double, duration: Double) -> CutPreview?
}
```
Semantics: `cutSegment` → the segment under `t` if visible (kind `.cut`); `restoreSegment` → segment under `t` if hidden (`.restore`); `trimStart` → `[0, t)` snapped like `cut`, `.cut`, `pendingSplitAt = t` when `t` is not an existing boundary; `trimEnd` symmetric; `clearAll` → `cutRanges(segments)`, `.restore`, nil if none hidden. Every case returns nil when `cut`/`setHidden` would return the input unchanged.

Transport bar (`trimControls` + `splitControls` become one `cutControls` group, in order): Split `square.split.2x1` · Cut/Restore `eye.slash`/`eye` · **Trim Start** (text button, help "Cut everything before the playhead") · **Trim End** (help "Cut everything after the playhead") · Clear `xmark.circle` (help "Clear all splits & cuts", disabled `!canResetSegments`) · "N cut" readout. Remove `Set In`, `Set Out`, `scissors`, both `arrow.uturn.backward`, the `in – out` text. Each cut-type button gets:
```swift
.onHover { model.setHoverPreview($0 ? .trimStart : nil) }
```
and its action closure sets `model.hoverAction = nil` first. **The preview is derived, not stored:** `var hoverPreview: CutPreview? { hoverAction.flatMap { TimelineSegments.preview(for: $0, segments: segments, at: currentTime, duration: duration) } }` — so it tracks the playhead during playback, and goes nil by itself when the action would change nothing (= the button is disabled; covers the ticket's "clears when disabled"). `export()` sets `hoverAction = nil` before `exportState = .exporting(0)`. Rename `setHoverPreview` → plain property writes.

- [ ] **Step 1: Failing tests**

```swift
@Test func previewTrimStartIsHeadRangeWithPendingSplit()  // full 10, t 3 → ranges [0..<3], .cut, pendingSplitAt 3
@Test func previewTrimStartOnExistingBoundaryHasNoPendingSplit() // split at 3 first → pendingSplitAt nil
@Test func previewCutSegmentIsSegmentUnderPlayhead()     // split at 4; t 5 → [4..<10], .cut
@Test func previewRestoreOnlyForHiddenSegment()          // visible → nil; hidden → range, .restore
@Test func previewClearAllListsEveryHiddenRun()          // two cuts → both ranges, .restore; none → nil
@Test func previewIsNilWhenActionWouldNotChangeAnything() // trimStart at t 0 → nil; trimEnd at duration → nil
```
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** helpers, model property, transport bar. In `preview(for:)` evaluate the input list once and compare against that instance (B1 trap). **Step 4: Run** — PASS; `swift build`.
- [ ] **Step 5: Grep gate** — `grep -rn 'arrow.uturn' Sources/CaptureStudio/Studio/StudioTransportBar.swift` → no matches; `grep -rn 'TrimTimeline\|committedTrim\|trimIn\|trimOut' Sources` → only the four `EditState` legacy fields and `LegacyTrimMigration`.
- [ ] **Step 6: Commit (after confirmation)** — `feat(studio): hover preview model for cut actions; single clear button in the transport bar`

### Task 7 (B6): draw the hover preview on the timeline

**Files:**
- Create: `Sources/CaptureStudio/Studio/CutPreviewOverlay.swift`
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` (`timeline` ~L334-375, `timelineStack` ~L191-230)

**Interfaces (Consumes):** `model.hoverPreview`, `model.duration`.

```swift
/// One view, two styles: `.lane` = tint + 1pt border per range + pending-split
/// marker on the master lane; `.dim` = faint wash across the whole lane stack.
struct CutPreviewOverlay: View {
    enum Style { case lane, dim }
    let preview: CutPreview?; let duration: Double; let width: CGFloat; let style: Style
}
```
Colours: `.cut` → `Color.red.opacity(0.28)` fill + `Color.red.opacity(0.8)` border; `.restore` → `Color.green.opacity(0.25)` + `Color.green.opacity(0.8)`. Dim overlay: `Color.black.opacity(0.18)` for `.cut`, `Color.green.opacity(0.08)` for `.restore`; `.allowsHitTesting(false)` on both. Pending split: 1pt `.primary` line, full lane height, dashed (`StrokeStyle(dash: [2,2])`).

- [ ] **Step 1:** Add `CutPreviewOverlay(preview: model.hoverPreview, duration: model.duration, width: width, style: .lane)` as the last child of the `timeline` ZStack (above hidden segments, below the playhead). Remove the `trimIn/trimOut` kept-region rect (full-width `.tint` bar instead).
- [ ] **Step 2:** In `timelineStack`, `.overlay(alignment: .topLeading) { CutPreviewOverlay(preview: model.hoverPreview, duration: model.duration, width: contentWidth, style: .dim) }` on the inner `VStack` (inside the ScrollView so it scrolls with the lanes).
- [ ] **Step 3: Build + manual check** — hover each of Cut / Restore / Trim Start / Trim End / Clear: highlight matches exactly the range the click then changes, disappears on hover exit and after click, nothing shown when the button is disabled or during export; hovering Trim End while playing: highlight follows the playhead. Trim End in the real app: playhead readout stays at the trim point, does not jump to the end (Review Focus 6). Also: open an old bundle with an applied trim → identical visible result, Restore (eye) on the head/tail brings the trimmed part back; export of a trimmed+mid-cut project matches preview (text/camera/zoom blocks, cursor, audio).
- [ ] **Step 4:** `swift test` green.
- [ ] **Step 5: Commit (after confirmation)** — `feat(studio): timeline overlay previewing the range a cut action will change`
- [ ] **Step 6: Board** — `pm task move --id 4nkhM2OIkGko --status completed`.

---

## Part C — undo / redo (`NITZEw6B_gX1`)

### Task 8 (C1): `EditHistory` value type

**Files:**
- Create: `Sources/CaptureStudio/Studio/EditHistory.swift`
- Test: `Tests/CaptureStudioTests/EditHistoryTests.swift` (new)

**Interfaces (Produces):**
```swift
/// Snapshot history. `record(_:)` is the single entry point: pass the state
/// after every committed change; the previous state becomes the undo step.
/// Identical consecutive states are not recorded (coalescing).
struct EditHistory<State: Equatable> {
    init(initial: State, cap: Int = 100)
    private(set) var current: State
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    mutating func record(_ state: State)          // pushes old `current` to undo, clears redo, drops oldest past `cap`
    mutating func undo() -> State?                // moves current → redo, returns new current
    mutating func redo() -> State?
    mutating func reset(to state: State)          // clears both stacks (used on load)
    mutating func replaceCurrent(_ state: State)  // overwrite `current` without touching either stack
}
```

- [ ] **Step 1: Failing tests** (State = `Int`)

```swift
@Test func recordThenUndoReturnsPrevious()     // init 0; record 1; undo() == 0; canRedo
@Test func redoReappliesUndone()               // … redo() == 1
@Test func identicalStateIsNotRecorded()        // record 1; record 1 → canUndo true once; undo → 0; undo → nil
@Test func newRecordClearsRedo()               // record 1; undo; record 2 → !canRedo
@Test func capDropsOldest()                    // cap 3; record 1,2,3,4 → undo×3 ok (3,2,1), 4th undo nil
@Test func undoOnEmptyIsNil()                  // init 0 → undo() nil, redo() nil
@Test func replaceCurrentKeepsStacks()         // record 1; replaceCurrent(5) → undo() == 0; redo() == 5
```
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit (after confirmation)** — `feat(studio): EditHistory snapshot stack`

### Task 9 (C2): `applyEdit(_:)` — one place that writes an `EditState` into the model

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (load ~L585-645)

**Interfaces (Produces):**
```swift
/// Push `edit`'s fields into the model (camera, crop, background, blocks,
/// subtitles, segments, frame, volumes, cursor flags). Does not persist, does
/// not touch history. Used by `load()` and by undo/redo.
private func applyEdit(_ edit: EditState)
```
- [ ] **Step 1:** Move the `cameraHomeLayout = …` … `frameEnabled/frame…` block out of `load()` into `applyEdit`, with `loadOverlayData(display:)` staying in `load()` (cursor data is not edit state) and `loadBackgroundImage()` staying inside `applyEdit` (image depends on `canvasBackgroundImage`). `segments` normalisation stays inside. `load()` becomes `applyEdit(edit)` + the overlay/preview setup.
- [ ] **Step 2:** After `applyEdit` in the undo/redo path (Task C3) call, in order: `rebuildPreview()` **unconditionally** (swaps the player item: required because `refreshPlayerItemForCanvasChange` ~L2401 exists for crop-aspect shape changes, `needsCompositor` flips swap the item, and `rerenderPausedFrame` ~L2223 documents that a paused frame does not repaint on `videoComposition` reassignment), re-derive transients (`templateGuideVisible = cropAspect == .nineBySixteenTemplate`; `panVideoMode = false` when the reframe is not pannable; `subtitleSelected = false` when `subtitles == nil`), drop any `selected*ID` whose block no longer exists (reuse the five lines deleted from `applyTrim` in B3), `settlePlayhead()`.
- [ ] **Step 3:** `swift build && swift test` green; manual: open a bundle → looks identical to before.
- [ ] **Step 4: Commit (after confirmation)** — `refactor(studio): applyEdit funnel shared by load and history`

### Task 10 (C3): wire history into `saveEdit()`; undo/redo on the model

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (`saveEdit` ~L2852, load)
- Test: `Tests/CaptureStudioTests/StudioModelCutTests.swift` (extend)

**Interfaces (Produces):**
```swift
private var history = EditHistory(initial: EditState())
var canUndo: Bool { !isExporting && history.canUndo }
var canRedo: Bool { !isExporting && history.canRedo }
func undo()
func redo()
```
- `saveEdit()` → `let e = currentEdit(); history.record(e); try? bundle.writeEdit(e)`. Nothing else changes: drags call `moveX` per frame and `commitXEdit()` once, so one `record` per gesture; `CaptionTextEditor` commits once per edit.
- `load()` → after `applyEdit`, `history.reset(to: currentEdit())`.
- `undo()` → `guard canUndo, let s = history.undo() else { return }; applyEdit(s); <C2 step-2 sequence>; let e = currentEdit(); history.replaceCurrent(e); try? bundle.writeEdit(e)`. Record what was *actually applied* (`applyEdit` normalises segments, clamps frame, may drop a missing background image), otherwise the next `saveEdit()` records a spurious no-op step. Must **not** call `saveEdit()` (would re-record). `redo()` mirrors.
- **State outside `EditState`:** `deleteBackgroundImage()` (~L2360) removes the file from the bundle, so undoing it would restore a dangling reference. Make it non-destructive: only clear `canvasBackgroundImage` and save; leave the file (orphan; `uploadBackgroundImage` overwrites it on next upload). Document as accepted limitation: undoing an *upload* that replaced an earlier image cannot bring the earlier file back.
- `history` must be `@Published` or `canUndo/canRedo` must be driven by `objectWillChange` — mark `@Published private var history` so the app bar buttons refresh.

- [ ] **Step 1: Failing tests** (model via `loadForTests(duration: 10)`; it must also `history.reset(to: currentEdit())`)

```swift
@Test func splitIsOneUndoStep() { let m = model(); m.seek(to: 4); m.splitAtPlayhead(); #expect(m.canUndo); m.undo(); #expect(m.segments.isEmpty); #expect(m.canRedo); m.redo(); #expect(m.segments.count == 2) }
@Test func undoRestoresSegments() { let m = model(); m.seek(to: 3); m.trimStartAtPlayhead(); m.undo()
    #expect(m.segments.isEmpty); #expect(m.currentTime == 3) }   // preview rebuild needs a player → manual check (Review Focus 4)
@Test func dragCoalescesIntoOneStep() { let m = model(); m.seek(to: 2); m.addTextBlock(); let id = m.textBlocks[0].id; let b0 = m.textBlocks[0].begin
    m.moveTextBlock(id, toBegin: 3); m.moveTextBlock(id, toBegin: 4); m.commitTextEdit(); m.undo(); #expect(m.textBlocks[0].begin == b0) }
@Test func selectionChangeIsNotAStep() { let m = model(); m.seek(to: 2); m.addTextBlock(); let n = m.canUndo; m.selectTextBlock(nil); m.selectTextBlock(m.textBlocks[0].id)
    m.undo(); #expect(m.textBlocks.isEmpty) }   // selectTextBlock calls saveEdit(); equality-coalescing must swallow it
@Test func newEditAfterUndoClearsRedo() { … split; undo; split at other t → !canRedo }
@Test func undoDisabledWhileExporting() { … split; beginExportLockForTests(); #expect(!m.canUndo) }
```
`addTextBlock()` (~L1540) takes no arguments and inserts at the playhead. `selectTextBlock(_:)` calls `saveEdit()` on change (~L1600) — history relies on `EditHistory.record`'s equality coalescing to not create a step there, so `identicalStateIsNotRecorded` (C1) is mandatory.

- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS; whole suite green.
- [ ] **Step 5: Commit (after confirmation)** — `feat(studio): multi-level undo/redo recorded at every saved edit`

### Task 11 (C4): app-bar buttons + ⌘Z / ⇧⌘Z

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioAppBar.swift:19-24`
- Create: `Sources/CaptureStudio/Studio/UndoKeyCatcher.swift`
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` (install the catcher in the root view's `.background`)

- [ ] **Step 1: App bar** — replace the two `.comingSoon()` buttons:
```swift
Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
    .disabled(!model.canUndo).help("Undo")
Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
    .disabled(!model.canRedo).help("Redo")
```
- [ ] **Step 2: Key catcher** — `UndoKeyCatcher: NSViewRepresentable` modelled on `CanvasEventCatcher` (local monitor, `.keyDown`, same `event.window == window` check), **without** the bounds check. Handle: `⌘Z` (no shift) → `model.undo()`, `⇧⌘Z` → `model.redo()`, return `nil`; pass the event through when `model.isExporting`, when `window.firstResponder is NSText` (covers `NSTextView`), or for any other key. Match on `event.keyCode == 6` (the Z key; `charactersIgnoringModifiers` returns `"Z"` with ⇧ held, so a `== "z"` string check would never fire redo) and `modifierFlags.intersection(.deviceIndependentFlagsMask)` equal to `[.command]` / `[.command, .shift]`. The app is `MenuBarExtra`-only with Studio windows as plain `NSWindow`s; SwiftUI still installs a default main menu whose Edit ▸ Undo sends `undo:` down the responder chain, which is how the passed-through event reaches the text view (`allowsUndo = true`, `CaptionTextEditor.swift:31`). If the manual check shows ⌘Z doing nothing inside the caption field, have the catcher call `(window.firstResponder as? NSTextView)?.undoManager?.undo()` / `.redo()` instead of returning the event.
- [ ] **Step 3: Manual checks** — each of: split, cut/restore, clear, trim start/end, add/move/resize/delete text·camera·shape·zoom blocks, crop/camera-style change → ⌘Z reverts in one step, ⇧⌘Z re-applies; with the player **paused**: undo a crop-aspect change and undo adding the first text block → the frame repaints correctly (Review Focus 4); drag a block across the timeline → one ⌘Z; ⌘Z inside an active caption text field edits the text (not the timeline); buttons grey during export; reopen the bundle after undo → `edit.json` reflects the restored state.
- [ ] **Step 4:** `swift build && swift test` green; `grep -n comingSoon Sources/CaptureStudio/Studio/StudioAppBar.swift` → only Presets / speed remain.
- [ ] **Step 5: Commit (after confirmation)** — `feat(studio): wire Undo/Redo buttons and ⌘Z / ⇧⌘Z`
- [ ] **Step 6: Board** — `pm task move --id NITZEw6B_gX1 --status completed`; also `gcznZn00d2qD` after Part A.

---

## Self-review notes

- Spec coverage: A ✔ (pause, guard, no resume). B: trim=split+cut ✔ B4; apply/readout/trimUndo removal ✔ B3; export range ✔ B3; playback respects leading/trailing cuts ✔ B3 (`togglePlay`, load seek) + B4 (`settlePlayhead`); hover preview ✔ B5/B6 incl. pending split marker, restore colour, clear-all, disabled/exit/press clearing; one clear button non-undo glyph ✔ B5; back-compat migration incl. rebased blocks ✔ B2; unit tests ✔ B1/B2/B4/B5. C: snapshot history ✔ C1; funnel ✔ C3; coalescing ✔ C3 (by construction + test); not-undoable list ✔ (none of those are in `EditState`); in-memory only ✔; buttons/shortcuts/text-field exemption/export-disabled ✔ C4; `trimUndo` removal ✔ B3; tests ✔ C1/C3.
- Scrutiny pass (2026-11-06, fresh reviewer agent against the code) found 13 issues; all folded in above: UUID-equality trap in "unchanged?" checks (B1/B4/B5), time-observer clamp for trailing cuts (B3), `keyCode == 6` for ⇧⌘Z (C4), unconditional `rebuildPreview()` + transient re-derivation after undo (C2), non-destructive `deleteBackgroundImage` + record-applied-state (C3), derived `hoverPreview` (B5), inverted-marker rule + clamps in migration (B2), vacuous preview test removed (C3), one overlay view (B6), legacy-defaults write test (B2). Tooltips stay plain "Undo"/"Redo" (ticket allows).
- Open risk (flagged, not a plan gap): `history.record` runs `currentEdit()` + `EditState ==` on every save. With a long subtitle track this is O(cues) per commit — fine for commits, would not be fine per drag frame; the plan keeps per-frame paths off `saveEdit()`, so audit any new caller that saves per frame.
