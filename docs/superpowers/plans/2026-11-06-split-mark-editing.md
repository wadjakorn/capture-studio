# Split-mark editing, hidden-run invariant, trim collapse — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `docs/superpowers/specs/2026-11-06-split-mark-editing-design.md` on branch `feat/studio-cut-model-undo`: adjacent hidden segments always merge (so trims leave one cut segment), split marks on the lane open a popover (Remove split / Cut-or-Restore a side), the Cut control uses `scissors`, and the "hide cut material" feature is filed as a ticket.

**Architecture:** One pure pass `TimelineSegments.coalescedHidden` enforced inside `cut`, `setHidden` and `normalized` makes the invariant hold everywhere segments enter the model (user action, load, undo snapshot, migration). Mark actions are id-based `CutAction` cases carried through the existing `hoverAction → hoverPreview → CutPreviewOverlay` pipeline and a single `StudioModel.perform(_:)` entry so each is one `saveEdit` undo step. The lane view gains per-mark hit targets and a `.popover` keyed by the right-hand segment id; a pure `SplitMarkMenu` decides which items the popover shows.

**Tech Stack:** Swift 6 / SwiftUI / AVFoundation, swift-testing 0.12.0, CLT only.

**Spec:** `docs/superpowers/specs/2026-11-06-split-mark-editing-design.md` (owner decisions D1–D5; "my call" items are already settled there).

## Global Constraints

- CLT-only toolchain: never bump swift-testing (`0.12.0`) / KeyboardShortcuts (`1.10.0`); no `#Preview`.
- `swift build` and `swift test` green after every task (baseline 540 tests at `f02c548`).
- Branch `feat/studio-cut-model-undo`; per-task commits authorised (2026-11-06); **no push, no merge** without asking. Commit trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Board `PM_API=http://wadjakorn-bmax:3000`; one legal edge per move; ticket `4nkhM2OIkGko` → `doing` before Task 1, → `completed` in Task 7 (if an edge is rejected, walk legal edges one at a time; if it never left `completed`, skip).
- UUID trap: `TimelineSegment` is `Equatable` incl. `id`; `full(duration:)` / `effectiveSegments` on `[]` mint fresh ids per call — read once, compare against that instance.
- Invariant after Task 1: no two adjacent segments both `hidden`; segments sorted and tiling `[0, duration]`.
- After Task 6: no `eye*` / `arrow.uturn*` glyph in `StudioTransportBar.swift`.

## Review Focus

1. **Undo snapshot containing adjacent hidden segments** (history recorded before Task 1 cannot exist in a fresh session, but a legacy `edit.json` can) — `applyEdit` must coalesce via `normalized`. → Task 1 `normalizedCoalescesAdjacentHidden`, Task 2 `loadCoalescesLegacyAdjacentHidden`.
2. **Trim Start with the playhead inside the first visible segment after a hidden head** (`[0,2)h [2,8) [8,10)`, t=5) — head grows to `[0,5)h`, one segment. → Task 2 `trimStartGrowsHiddenHeadIntoOneSegment`.
3. **"Cut the part before" when the left segment is the last visible one** — item disabled, preview nil, model refuses. → Task 3 `previewHideSegmentIDNilForLastVisible`, Task 4 `menuDisablesCutOfLastVisible`.
4. **⌘Z while the popover is open removes the anchored mark** — popover must dismiss and `hoverAction` must clear. → Task 5 manual check + `onChange` guard.
5. **Marks closer than 16 pt at the current zoom** — hit rects must not overlap and every mark stays reachable. → Task 5 `hitRectsNeverOverlapAndCoverEveryMark`.

---

### Task 1 (T1): hidden-run invariant in the pure model

**Files:**
- Modify: `Sources/CaptureStudio/Studio/TimelineSegments.swift` (`normalized`, `canSplit`, `split`, `setHidden`, `cut`)
- Test: `Tests/CaptureStudioTests/TimelineSegmentsTests.swift`

**Interfaces:**
- Produces: `static func coalescedHidden(_ segments: [TimelineSegment]) -> [TimelineSegment]` — sorts; each maximal run of consecutive `hidden == true` segments becomes one segment `[run.first.start, run.last.end)` keeping `run.first.id`; visible segments untouched; idempotent; returns the input instance when nothing merges.
- `normalized(_:duration:)`, `setHidden(_:id:_:)` (when hiding) and `cut(_:range:minWidth:)` return `coalescedHidden(result)`. `split` / `canSplit` refuse when the spanning segment is `hidden` (return `(sorted, nil)` / `false`).

- [ ] **Step 0: Board** — `PM_API=http://wadjakorn-bmax:3000 pm task move --id 4nkhM2OIkGko --status doing` (walk legal edges; if rejected, note it and continue).

- [ ] **Step 1: Write the failing tests** (replace `splitPreservesHiddenFlag`; add a `// MARK: hidden-run invariant` section)

```swift
@Test func splitRefusedInsideHiddenSegment() {
    let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<4)
    #expect(!TimelineSegments.canSplit(s, at: 2))
    #expect(TimelineSegments.split(s, at: 2).id == nil)
    #expect(TimelineSegments.canSplit(s, at: 6))
}
@Test func coalescedHiddenMergesRunsKeepingFirstId() {
    let a = seg(0, 2, hidden: true), b = seg(2, 5, hidden: true), c = seg(5, 7), d = seg(7, 9, hidden: true), e = seg(9, 10, hidden: true)
    let out = TimelineSegments.coalescedHidden([a, b, c, d, e])
    #expect(out.map(\.start) == [0, 5, 7]); #expect(out.map(\.end) == [5, 7, 10])
    #expect(out.map(\.hidden) == [true, false, true])
    #expect(out[0].id == a.id && out[2].id == d.id && out[1] == c)
}
@Test func coalescedHiddenIsIdentityWhenNothingAdjacent() {
    let s = [seg(0, 2, hidden: true), seg(2, 5), seg(5, 10, hidden: true)]
    #expect(TimelineSegments.coalescedHidden(s) == s)
    #expect(TimelineSegments.coalescedHidden(TimelineSegments.coalescedHidden(s)) == s)
}
@Test func normalizedCoalescesAdjacentHidden() {
    let s = [seg(0, 2, hidden: true), seg(2, 4, hidden: true), seg(4, 10)]
    let n = TimelineSegments.normalized(s, duration: 10)
    #expect(n.count == 2); #expect(n[0].hidden && n[0].end == 4)
}
@Test func cutAdjacentToHiddenRunMergesIntoIt() {
    var s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<2)
    s = TimelineSegments.cut(s, range: 2..<5)
    #expect(s.count == 2); #expect(s[0].hidden && s[0].start == 0 && s[0].end == 5)
}
@Test func setHiddenMergesWithNeighbours() {
    var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 3).segments
    s = TimelineSegments.split(s, at: 6).segments
    s = TimelineSegments.setHidden(s, id: s[0].id, true)
    s = TimelineSegments.setHidden(s, id: s[1].id, true)
    #expect(s.count == 2); #expect(s[0].hidden && s[0].end == 6); #expect(!s[1].hidden)
}
@Test func cutOverSplitsCollapsesThemIntoOneHiddenSegment() {
    var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 2).segments
    s = TimelineSegments.split(s, at: 4).segments
    let t = TimelineSegments.cut(s, range: 0..<6)
    #expect(t.count == 2); #expect(t[0].hidden && t[0].end == 6); #expect(t[1].start == 6)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TimelineSegmentsTests 2>&1 | tail -20`
Expected: compile error on `coalescedHidden`; `splitRefusedInsideHiddenSegment` would fail.

- [ ] **Step 3: Implement** `coalescedHidden` and wire it into `normalized`, `setHidden` (hide path only), `cut` (final `out`), plus the hidden guard in `canSplit` / `split`. Update the doc comments on `TimelineSegment` ("adjacent hidden segments are always merged"), `split` ("refused inside a hidden segment") and `cut` ("a bound inside a hidden run no longer splits; the run simply absorbs the cut — `[0,4)h [4,10)` cut `2..<6` → `[0,6)h [6,10)`, cut `2..<3` → unchanged").

- [ ] **Step 4: Run the whole suite**

Run: `swift test 2>&1 | tail -5`
Expected: all pass. `cutPreservesExistingHiddenInsideRange`, `previewRestoreOnlyForHiddenSegment`, `LegacyTrimMigrationTests` (range-only assertions) stay green unmodified.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/TimelineSegments.swift Tests/CaptureStudioTests/TimelineSegmentsTests.swift
git commit -m "feat(studio): adjacent hidden segments always merge; no split inside a cut"
```

---

### Task 2 (T2): StudioModel follows the invariant

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` — `setSegments` (~line 1447), doc comments on `trimStartAtPlayhead` / `trimEndAtPlayhead` / `canSplitAtPlayhead`
- Modify: `Sources/CaptureStudio/Studio/StudioTransportBar.swift` — tooltips of Trim Start/End: "Cut everything before the playhead (merges into one cut)" / "Cut everything after the playhead (merges into one cut)"
- Test: `Tests/CaptureStudioTests/StudioModelCutTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: `setSegments(_:)` stores `[]` when the list is a single visible segment (so `canResetSegments` goes false and the "N cut" label hides). Everything else keeps its name.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func trimStartCollapsesSplitsInHead() {
    let m = model()
    m.seek(to: 2); m.splitAtPlayhead()
    m.seek(to: 4); m.splitAtPlayhead()
    m.seek(to: 6); m.trimStartAtPlayhead()
    #expect(m.segments.count == 2)
    #expect(m.segments[0].hidden && m.segments[0].start == 0 && m.segments[0].end == 6)
    #expect(m.currentTime == 6)
}
@Test func trimEndCollapsesSplitsInTail() {
    let m = model()
    m.seek(to: 6); m.splitAtPlayhead()
    m.seek(to: 8); m.splitAtPlayhead()
    m.seek(to: 4); m.trimEndAtPlayhead()
    #expect(m.segments.count == 2)
    #expect(m.segments[1].hidden && m.segments[1].start == 4 && m.segments[1].end == 10)
    #expect(m.currentTime == 4)
}
@Test func trimStartGrowsHiddenHeadIntoOneSegment() {
    let m = model()
    m.seek(to: 2); m.trimStartAtPlayhead()
    m.seek(to: 8); m.splitAtPlayhead()
    m.seek(to: 5); m.trimStartAtPlayhead()
    #expect(m.segments.map(\.start) == [0, 5, 8]); #expect(m.segments[0].hidden)
}
@Test func splitDisabledInsideCut() {
    let m = model()
    m.seek(to: 4); m.trimStartAtPlayhead()
    m.seek(to: 2)
    #expect(!m.canSplitAtPlayhead)
    m.splitAtPlayhead()
    #expect(m.segments.count == 2)
}
@Test func loadCoalescesLegacyAdjacentHidden() {
    let m = StudioModel(bundleURL: URL(fileURLWithPath: "/tmp/cut-test-legacy.capturestudio"))
    m.loadForTests(duration: 10, segments: [TimelineSegment(start: 0, end: 2, hidden: true),
                                            TimelineSegment(start: 2, end: 4, hidden: true),
                                            TimelineSegment(start: 4, end: 10)])
    #expect(m.segments.count == 2)
}
@Test func trimStartIsOneUndoStep() {
    let m = model()
    m.seek(to: 2); m.splitAtPlayhead()
    m.seek(to: 4); m.splitAtPlayhead()
    let before = m.segments
    m.seek(to: 6); m.trimStartAtPlayhead()
    m.undo()
    #expect(m.segments == before)
}
```

- [ ] **Step 2: Run to verify** — `swift test --filter StudioModelCutTests 2>&1 | tail -20`. Expected: with Task 1 in place `trimStartCollapsesSplitsInHead`, `trimEndCollapsesSplitsInTail`, `trimStartGrowsHiddenHeadIntoOneSegment`, `splitDisabledInsideCut`, `loadCoalescesLegacyAdjacentHidden` already PASS (the invariant lives in the primitives); `trimStartIsOneUndoStep` passes too. This task's code change is `setSegments` normalisation (tested in Task 4 `removingLastSplitLeavesTimelineUncut`); keep these tests as pins.

- [ ] **Step 3: Implement** in `setSegments`: `segments = (list.count == 1 && !list[0].hidden) ? [] : list`. Update doc comments and the two tooltips.

- [ ] **Step 4: Run** `swift test 2>&1 | tail -5` — all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift Sources/CaptureStudio/Studio/StudioTransportBar.swift Tests/CaptureStudioTests/StudioModelCutTests.swift
git commit -m "fix(studio): trims collapse the trimmed side into one cut; uncut list normalises to empty"
```

---

### Task 3 (T3): `join`, id-based CutAction cases, merge preview

**Files:**
- Modify: `Sources/CaptureStudio/Studio/TimelineSegments.swift` (`join`, `CutAction`, `CutPreview`, `preview(for:…)`)
- Modify: `Sources/CaptureStudio/Studio/CutPreviewOverlay.swift`
- Test: `Tests/CaptureStudioTests/TimelineSegmentsTests.swift`

**Interfaces:**
- Produces:
  - `static func join(_ segments: [TimelineSegment], atBoundaryOf rightID: UUID) -> [TimelineSegment]` — finds the segment with `id == rightID`; if it is first, missing, or its left neighbour's `hidden` differs, returns the input instance; else replaces left+right by one segment `[left.start, right.end)` with `left.id` and `left.hidden`.
  - `enum CutAction: Equatable { case cutSegment, restoreSegment, trimStart, trimEnd, clearAll, removeSplit(rightID: UUID), hideSegmentID(UUID), restoreSegmentID(UUID) }`
  - `CutPreview.Kind` adds `.merge`; `CutPreview` adds `var removingSplitAt: Double? = nil`. Existing initialisers/tests keep working (`pendingSplitAt` stays; new field has a default).
  - `preview(for:…)`: `.removeSplit(rightID)` → `CutPreview(ranges: [], kind: .merge, removingSplitAt: right.start)` when `join` changes the list, else nil. `.hideSegmentID(id)` → `CutPreview(ranges: [seg.start..<seg.end], kind: .cut)` when `setHidden(s, id, true) != s`, else nil. `.restoreSegmentID(id)` → `.restore` range when the segment is hidden. These ignore `t`.
  - `CutPreviewOverlay`: `.merge` draws only a dashed line at `removingSplitAt` in the accent colour (reuse the pending-split path with `Color.accentColor`), no ranges, (`.dim` naturally draws nothing for `.merge` because `ranges` is empty).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func joinMergesVisibleNeighboursKeepingLeftId() {
    let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
    let j = TimelineSegments.join(s, atBoundaryOf: s[1].id)
    #expect(j.count == 1); #expect(j[0].id == s[0].id); #expect(j[0].start == 0 && j[0].end == 10 && !j[0].hidden)
}
@Test func joinRefusedForMixedFlagsFirstSegmentAndUnknownId() {
    let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<4)   // [0,4)h [4,10)
    #expect(TimelineSegments.join(s, atBoundaryOf: s[1].id) == s)
    #expect(TimelineSegments.join(s, atBoundaryOf: s[0].id) == s)
    #expect(TimelineSegments.join(s, atBoundaryOf: UUID()) == s)
}
@Test func previewRemoveSplitIsMergeMarker() {
    let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
    let p = TimelineSegments.preview(for: .removeSplit(rightID: s[1].id), segments: s, at: 0, duration: 10)
    #expect(p == CutPreview(ranges: [], kind: .merge, removingSplitAt: 4))
    let mixed = TimelineSegments.cut(s, range: 0..<4)
    #expect(TimelineSegments.preview(for: .removeSplit(rightID: mixed[1].id), segments: mixed, at: 0, duration: 10) == nil)
}
@Test func previewHideSegmentIDNilForLastVisible() {
    let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<4)
    #expect(TimelineSegments.preview(for: .hideSegmentID(s[1].id), segments: s, at: 0, duration: 10) == nil)
    #expect(TimelineSegments.preview(for: .restoreSegmentID(s[0].id), segments: s, at: 9, duration: 10)
            == CutPreview(ranges: [0..<4], kind: .restore))
    let two = TimelineSegments.split(s, at: 7).segments
    #expect(TimelineSegments.preview(for: .hideSegmentID(two[1].id), segments: two, at: 0, duration: 10)
            == CutPreview(ranges: [4..<7], kind: .cut))
}
```

- [ ] **Step 2: Run** `swift test --filter TimelineSegmentsTests 2>&1 | tail -20` — compile errors on `join`, new cases.

- [ ] **Step 3: Implement** per Interfaces. In `CutPreviewOverlay.content`, switch on `preview.kind` (3-way) instead of `isCut: Bool`.

- [ ] **Step 4: Run** `swift test 2>&1 | tail -5` — all pass (existing preview tests compare `CutPreview` values with `pendingSplitAt:`; the new field defaults to nil so they stay valid).

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/TimelineSegments.swift Sources/CaptureStudio/Studio/CutPreviewOverlay.swift Tests/CaptureStudioTests/TimelineSegmentsTests.swift
git commit -m "feat(studio): join primitive and id-based cut actions with merge preview"
```

---

### Task 4 (T4): model entry point + popover menu model

**Files:**
- Create: `Sources/CaptureStudio/Studio/SplitMarkMenu.swift`
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (split & cut section)
- Modify: `Sources/CaptureStudio/Studio/StudioTransportBar.swift` — move `timecode(_:)` to `static func TimelineScale.timecode(_ seconds: Double) -> String` (same body) and call it from the transport
- Modify: `Sources/CaptureStudio/Studio/TimelineScale.swift` (new `static func timecode(_:)`)
- Test: `Tests/CaptureStudioTests/SplitMarkMenuTests.swift` (new), `Tests/CaptureStudioTests/StudioModelCutTests.swift`

**Interfaces:**
- Consumes: Task 3 (`join`, `CutAction` id cases, `preview`).
- Produces:
  ```swift
  struct SplitMarkItem: Equatable, Identifiable {
      var id: String { title }
      let title: String      // "Remove split" | "Cut the part before (00:02.0–00:04.0)" | "Restore the part after (…)" …
      let action: CutAction
      let enabled: Bool
      let help: String?      // "Can't cut the last visible part" when disabled
  }
  enum SplitMarkMenu {
      /// Items for the mark at the start of segment `rightID`; nil when `rightID` is not a boundary.
      static func items(segments: [TimelineSegment], rightID: UUID) -> [SplitMarkItem]?
  }
  ```
  Rules: both visible → `[Remove split]` (`.removeSplit`). Mixed → two items, **left-side item first**: visible side → `Cut the part <before|after> (a–b)` with `.hideSegmentID`, `enabled = visibleCount > 1`; hidden side → `Restore the part <before|after> (a–b)` with `.restoreSegmentID`, always enabled. Both hidden → `nil` (cannot occur after Task 1; treat as not-a-boundary). Times formatted with `TimelineScale.timecode`, joined by U+2013 EN DASH `–` (not a hyphen). Spec amendment: the spec's `removeSplit(rightID:)` / `canRemoveSplit(rightID:)` are realised as `perform(_:)` / `splitMarkItems(rightID:)` below — no separate wrappers.
  - `StudioModel`:
    - `func perform(_ action: CutAction)` — `.removeSplit(rightID)` → `setSegments(join(...))` when changed; `.hideSegmentID(id)` → `hideSegment(id)`; `.restoreSegmentID(id)` → `restoreSegment(id)`; playhead-anchored cases call the existing methods. Always `hoverAction = nil` first. No-op while `isExporting`.
    - `func splitMarkItems(rightID: UUID) -> [SplitMarkItem]?` → `SplitMarkMenu.items(segments: effectiveSegments, rightID:)` (nil when `segments.isEmpty`).
    - Fix the latent UUID trap in `hideSegment`: compare `updated` against the `effectiveSegments` instance it was computed from; give `restoreSegment` the same `guard updated != s` for symmetry.

- [ ] **Step 1: Write the failing tests**

`SplitMarkMenuTests.swift`:
```swift
import Testing
import Foundation
@testable import CaptureStudio

struct SplitMarkMenuTests {
    @Test func bothVisibleOffersRemoveOnly() {
        let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
        let items = SplitMarkMenu.items(segments: s, rightID: s[1].id)!
        #expect(items.map(\.title) == ["Remove split"])
        #expect(items[0].action == .removeSplit(rightID: s[1].id)); #expect(items[0].enabled)
    }
    @Test func leftVisibleRightHiddenOffersCutBeforeThenRestoreAfter() {
        var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 2).segments
        s = TimelineSegments.cut(s, range: 4..<7)                        // [0,2) [2,4) [4,7)h [7,10)
        let items = SplitMarkMenu.items(segments: s, rightID: s[2].id)!
        #expect(items.map(\.title) == ["Cut the part before (00:02.0–00:04.0)", "Restore the part after (00:04.0–00:07.0)"])
        #expect(items[0].action == .hideSegmentID(s[1].id)); #expect(items[1].action == .restoreSegmentID(s[2].id))
        #expect(items.allSatisfy(\.enabled))
    }
    @Test func leftHiddenRightVisibleOffersRestoreBeforeThenCutAfter() {
        let s = TimelineSegments.cut(TimelineSegments.split(TimelineSegments.full(duration: 10), at: 7).segments, range: 0..<4)
        let items = SplitMarkMenu.items(segments: s, rightID: s[1].id)!   // [0,4)h | [4,7) [7,10)
        #expect(items.map(\.title) == ["Restore the part before (00:00.0–00:04.0)", "Cut the part after (00:04.0–00:07.0)"])
    }
    @Test func menuDisablesCutOfLastVisible() {
        let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<4)
        let items = SplitMarkMenu.items(segments: s, rightID: s[1].id)!
        #expect(items[1].title.hasPrefix("Cut")); #expect(!items[1].enabled)
        #expect(items[1].help == "Can't cut the last visible part")
    }
    @Test func firstSegmentAndUnknownIdAreNotBoundaries() {
        let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
        #expect(SplitMarkMenu.items(segments: s, rightID: s[0].id) == nil)
        #expect(SplitMarkMenu.items(segments: s, rightID: UUID()) == nil)
    }
}
```

`StudioModelCutTests.swift`:
```swift
@Test func removeSplitIsOneUndoStepAndRestoresMark() {
    let m = model()
    m.seek(to: 2); m.splitAtPlayhead(); m.seek(to: 6); m.splitAtPlayhead()
    let before = m.segments
    m.perform(.removeSplit(rightID: before[1].id))
    #expect(m.segments.map(\.start) == [0, 6])
    m.undo()
    #expect(m.segments == before)
}
@Test func removingLastSplitLeavesTimelineUncut() {
    let m = model()
    m.seek(to: 4); m.splitAtPlayhead()
    m.perform(.removeSplit(rightID: m.segments[1].id))
    #expect(m.segments.isEmpty); #expect(!m.canResetSegments)
}
@Test func performHideThenMarkIsGone() {
    let m = model()
    m.seek(to: 2); m.splitAtPlayhead()
    m.seek(to: 4); m.trimEndAtPlayhead()                 // [0,2) [2,4) [4,10)h
    m.perform(.hideSegmentID(m.segments[1].id))
    #expect(m.segments.map(\.start) == [0, 2]); #expect(m.segments[1].hidden)
}
@Test func performIsNoOpWhileExporting() {
    let m = model()
    m.seek(to: 4); m.splitAtPlayhead()
    let before = m.segments
    m.beginExportLockForTests()
    m.perform(.removeSplit(rightID: before[1].id))
    #expect(m.segments == before)
}
```

- [ ] **Step 2: Run** `swift test --filter "SplitMarkMenuTests|StudioModelCutTests" 2>&1 | tail -20` — compile errors.

- [ ] **Step 3: Implement** `SplitMarkMenu.swift`, `StudioModel.perform(_:)`, `splitMarkItems(rightID:)`, `TimelineScale.timecode`, the `hideSegment` comparison fix.

- [ ] **Step 4: Run** `swift test 2>&1 | tail -5` — all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/SplitMarkMenu.swift Sources/CaptureStudio/Studio/StudioModel.swift Sources/CaptureStudio/Studio/StudioTransportBar.swift Sources/CaptureStudio/Studio/TimelineScale.swift Tests/CaptureStudioTests/SplitMarkMenuTests.swift Tests/CaptureStudioTests/StudioModelCutTests.swift
git commit -m "feat(studio): split-mark menu model and id-based perform entry point"
```
(If `timecode` lands in a different existing file, stage that file instead of `TimelineScale.swift`.)

---

### Task 5 (T5): lane hit targets + popover

**Files:**
- Create: `Sources/CaptureStudio/Studio/SplitMarkHitTest.swift`
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` — `private var timeline` (~lines 339–385)
- Modify: `Sources/CaptureStudio/Studio/UndoKeyCatcher.swift` — `handle`: the `event.window == window` guard becomes `guard let w = event.window, w == window || w.parent == window` so ⌘Z still reaches the editor while an NSPopover (a child window) is key
- Test: `Tests/CaptureStudioTests/SplitMarkHitTestTests.swift` (new)

**Interfaces:**
- Consumes: `model.segments`, `model.splitMarkItems(rightID:)`, `model.perform(_:)`, `model.hoverAction`, `model.player?.pause()` / `model.togglePlay()` + `model.isPlaying`, `CutPreviewOverlay`.
- Produces:
  ```swift
  enum SplitMarkHitTest {
      /// x-ranges (points) for marks at `xs` (sorted, in points): each mark gets half the gap to its
      /// neighbours on either side, capped at `maxHalf` (8), clamped to [0, width]. Never overlapping.
      static func rects(xs: [CGFloat], width: CGFloat, maxHalf: CGFloat = 8) -> [ClosedRange<CGFloat>]
  }
  ```
  `rects` precondition (documented): `xs` sorted ascending (the model keeps `segments` sorted, so mark xs are too).
  Lane view changes (`StudioWindow.timeline`):
  - `@State private var openSplitID: UUID?`, `@State private var hoveredSplitID: UUID?`.
  - Keep the existing inner `ZStack` + seek `DragGesture` as is, except the tick for a mark whose id is `hoveredSplitID` or `openSplitID` renders 3 pt wide in `Color.accentColor`.
  - Add the hit targets as an **`.overlay(alignment: .leading)` on that ZStack, after the `.gesture` modifier** — siblings above the gesture view intercept hit-testing, so a press on a mark never reaches the seek drag (no `highPriorityGesture`). Inside the overlay:
    ```swift
    let marks = model.segments.filter { $0.start > 0.0001 }
    let xs = marks.map { fraction($0.start) * width }
    let rects = SplitMarkHitTest.rects(xs: xs, width: width)
    ForEach(Array(marks.enumerated()), id: \.element.id) { i, seg in
        Color.clear
            .frame(width: rects[i].upperBound - rects[i].lowerBound, height: 18)
            .contentShape(Rectangle())
            .pointerStyle(.link)                       // macOS 15: no NSCursor push/pop to balance
            .onHover { hoveredSplitID = $0 ? seg.id : (hoveredSplitID == seg.id ? nil : hoveredSplitID) }
            .onTapGesture { openSplitID = seg.id }
            .popover(isPresented: Binding(get: { openSplitID == seg.id },
                                          set: { if !$0 { openSplitID = nil } }),
                     arrowEdge: .bottom) { splitMarkPopover(rightID: seg.id) }
            .offset(x: rects[i].lowerBound)
    }
    ```
  - `splitMarkPopover(rightID:)`: `VStack(alignment: .leading, spacing: 2)` of `Button(item.title) { model.perform(item.action); openSplitID = nil }` `.disabled(!item.enabled)` `.help(item.help ?? "")` `.onHover { model.hoverAction = $0 ? item.action : nil }` over `model.splitMarkItems(rightID:) ?? []`; `.padding(8)`; `.onAppear { if model.splitMarkItems(rightID: rightID) == nil { openSplitID = nil } }`.
  - `.onChange(of: openSplitID)` on the timeline: opened → `if model.isPlaying { model.togglePlay() }`; closed (nil) → `model.hoverAction = nil`.
  - `.onChange(of: model.segments)`: if `openSplitID != nil` and `!model.segments.dropFirst().contains { $0.id == openSplitID }` → `openSplitID = nil`.
  - Playhead `Rectangle` gets `.allowsHitTesting(false)` (harmless with the overlay approach; keeps hover reachable under it).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import CaptureStudio

struct SplitMarkHitTestTests {
    @Test func isolatedMarkGetsCappedHalfWidth() {
        let r = SplitMarkHitTest.rects(xs: [100], width: 400)
        #expect(r == [92...108])
    }
    @Test func hitRectsNeverOverlapAndCoverEveryMark() {
        let xs: [CGFloat] = [10, 14, 15, 60, 300]
        let r = SplitMarkHitTest.rects(xs: xs, width: 320)
        #expect(r.count == xs.count)
        for (i, x) in xs.enumerated() { #expect(r[i].contains(x)) }
        for i in 1..<r.count { #expect(r[i - 1].upperBound <= r[i].lowerBound) }
    }
    @Test func rectsClampToLaneEdges() {
        let r = SplitMarkHitTest.rects(xs: [2, 398], width: 400)
        #expect(r[0].lowerBound == 0); #expect(r[1].upperBound == 400)
    }
}
```

- [ ] **Step 2: Run** `swift test --filter SplitMarkHitTestTests 2>&1 | tail -10` — compile error.

- [ ] **Step 3: Implement** `SplitMarkHitTest.rects` (neighbour half-gaps: `lo = max(x - maxHalf, i == 0 ? 0 : (xs[i-1] + x) / 2)`, `hi = min(x + maxHalf, i == last ? width : (x + xs[i+1]) / 2)`), then the lane view changes above.

- [ ] **Step 4: Run tests, build, relaunch**

Run: `swift test 2>&1 | tail -3 && scripts/build-app.sh debug && (pkill -x CaptureStudio; sleep 1; open dist/CaptureStudio.app)`
Expected: tests pass; app relaunches.

- [ ] **Step 5: Manual checks** (record outcomes in the task report)
  - Hover a mark: tick thickens/tints, pointer cursor; pressing it does not move the playhead.
  - Both-visible mark → popover "Remove split"; hover shows dashed accent line at the mark; click merges; ⌘Z brings the mark back.
  - Mixed mark → two items in the spec'd order; hovering shows red/green over the correct side; "Cut …" disabled with help when it is the last visible part.
  - Open a popover while playing → playback pauses; ⌘Z **with the popover key** undoes (UndoKeyCatcher child-window guard) and, when that removes the mark, the popover closes; no red/green wash remains after Esc / click-away.
  - After an item removes the hovered mark the cursor returns to the arrow (no stuck pointing hand).
  - Two marks 0.1 s apart at fit zoom are both reachable (zoom in if needed).

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/Studio/SplitMarkHitTest.swift Sources/CaptureStudio/Studio/StudioWindow.swift Sources/CaptureStudio/Studio/UndoKeyCatcher.swift Tests/CaptureStudioTests/SplitMarkHitTestTests.swift
git commit -m "feat(studio): click a split mark to remove it or choose cut/restore of a side"
```

---

### Task 6 (T6): scissors for Cut

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioTransportBar.swift` (~line 52)

- [ ] **Step 1:** `Image(systemName: cutIsRestore ? "rectangle.badge.plus" : "scissors")`
- [ ] **Step 2:** `grep -nE '"(eye|eye\.slash|arrow\.uturn[a-z.]*)"' Sources/CaptureStudio/Studio/StudioTransportBar.swift; echo "exit=$?"` → no matches, `exit=1`.
- [ ] **Step 3:** `swift build 2>&1 | tail -2` → succeeds.
- [ ] **Step 4: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioTransportBar.swift
git commit -m "fix(studio): use scissors for the Cut control, free the eye glyph"
```

---

### Task 7 (T7): board + final verification

- [ ] **Step 1: Create the `todo` ticket**

```bash
PM_API=http://wadjakorn-bmax:3000 pm task create --project DOgiocMzhN_l --status todo --priority medium \
  --title "[feature] studio: toggle hide/show cut material in the timeline (eye)" \
  --description "$(cat <<'MD'
## Problem
Cut (hidden) segments still take up their full width on the timeline. For a project with a long trimmed head/tail or many cuts, the user edits against a ruler that no longer matches what plays or exports; the text/camera/shape/zoom lanes stretch over material that will never be seen.

## Goal
One transport toggle, `eye` (showing cuts) / `eye.slash` (cuts hidden), that collapses every hidden range out of the timeline so the ruler, playhead and all lanes show the *output* timeline (what the preview already plays). Toggling back shows the full master timeline with the cut ranges visible again.

## Scope
- Transport toggle next to the cut controls; state is a Studio-session view preference (not persisted to edit.json, not undoable — same class as timeline zoom). Default: cuts shown (today's behaviour).
- Collapsed mode: timeline coordinate = `TimelineCut.map` of master time; ruler length = `remainingDuration`; playhead and all lanes (segments, zoom, camera, text, shape, subtitles) map through the same transform; blocks that fall entirely inside a cut are not drawn; blocks that straddle a cut are drawn with the cut part removed.
- A thin seam marker at each collapsed cut so the user can see where material was removed. Clicking a seam seeks to the cut's **end** (what `TimelineCut.unmap` resolves a seam to).
- `StudioModel.currentTime` stays master time (the player already runs the collapsed composition via `previewCuts`); only the timeline view transforms. Split/Cut/Trim therefore need no model changes. Restore-at-playhead and split-mark popovers on seams are disabled in collapsed mode (tooltip "Show cuts to restore a segment"); on entering collapsed mode, if the playhead sits inside a cut, settle it to that cut's end. Clear-all still works and its hover preview shows the seams in the restore colour.
- Hover preview (`CutPreviewOverlay`) ranges are mapped through the same transform.
- Dragging / resizing blocks in collapsed mode writes master times by unmapping the dragged edge's **absolute** collapsed position (`unmap` is piecewise, deltas cannot be unmapped). An edge dropped on a seam resolves asymmetrically: a block `end` → the cut's start, a block `begin` → the cut's end, so no block silently spans a cut.

## Acceptance
- Toggle collapses/expands instantly; preview playback and export are unaffected either way.
- In collapsed mode the ruler end equals the preview's duration and the playhead position matches the player clock.
- Every lane and the hover preview line up with the master view when toggled back; no block moves as a result of toggling.
- Unit tests for the pure mapping helpers (block spans, seams, playhead) over `cutRanges`.

## Out of scope
Per-segment visibility toggles, persisting the preference, changing cut semantics.
MD
)"
```
Expected: JSON with the new id and `"status_key": "todo"`; record the id.

- [ ] **Step 2:** `PM_API=http://wadjakorn-bmax:3000 pm task move --id 4nkhM2OIkGko --status completed` (legal edges one at a time; skip if it never left `completed`).

- [ ] **Step 3: Final verification**

Run: `swift test 2>&1 | tail -3 && git status --short && git log --oneline main..HEAD | wc -l`
Expected: all tests pass; clean tree; 20 commits on the branch.

---

## Scrutiny notes (reviewer, 2026-11-06 — "Execute with these edits", all folded in)

- All plan test expectations hand-traced and confirmed; no existing test breaks (migration tests are range-only; `trimInsideHiddenRunIsDisabled` still disabled).
- Blocking fixed: `UndoKeyCatcher` guarded `event.window == window`, so ⌘Z died while an NSPopover (child window) was key → accept `w.parent == window`.
- Blocking fixed: `.popover(item:)` with a UUID does not compile / anchors to the lane → per-mark `.popover(isPresented:)`.
- Hit targets moved to an `.overlay` above the seek gesture (child `highPriorityGesture` does not beat a parent `DragGesture(minimumDistance: 0)` on macOS).
- `.pointerStyle(.link)` instead of NSCursor push/pop (push leaked when the hovered mark vanished).
- `xs`/`rects` computation spelled out; sorted precondition documented.
- Spec API names amended to `perform(_:)` / `splitMarkItems(rightID:)`; en dash pinned; board step added; `restoreSegment` gets the same changed-guard.
