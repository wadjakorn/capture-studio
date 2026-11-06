# Split-mark editing, hidden-run invariant, trim collapse — Design

Date: 2026-11-06. Branch: `feat/studio-cut-model-undo` (on top of the shipped split-&-cut + undo work). Supersedes the pending plan `docs/superpowers/plans/2026-11-06-studio-trim-collapse-and-cut-icon.md` (its `merged`/`trimHead`/`trimTail` tasks are withdrawn; its icon and ticket tasks survive here).

## Intent

Manual testing of the split-&-cut branch found that split marks are permanent until "Clear all" and that trimming leaves stale marks on the trimmed side. The owner wants to edit marks directly, with behaviour defined by the state of the two segments touching a mark, and wants the model to never keep a mark between two cut parts.

## Goals

1. Remove one split mark directly on the timeline lane.
2. A mark between a visible and a cut segment forces an explicit choice: cut the visible side or restore the cut side.
3. A mark between two cut segments never exists (model invariant).
4. Trim Start / Trim End leave the trimmed side as one cut segment (follows from 3).
5. Cut-at-playhead uses the `scissors` glyph; the eye glyph is freed for a future "hide cut material in the timeline" toggle (ticket only).

## Non-goals / anti-goals

- No keyboard access to marks in this version.
- No per-segment visibility toggle in the lane, no collapsed-timeline view (separate ticket).
- Do not make split marks draggable.
- Anti-goal: any action that silently hides or restores material without the red/green hover preview the rest of the cut controls already give.

## Decisions (owner's, unless marked *my call*)

### D1 — Hidden-run invariant (owner: "A")

Adjacent hidden segments are always merged into one. Enforced by a pure pass `TimelineSegments.coalescedHidden(_:)` that merges each run of consecutive `hidden == true` segments into one segment keeping the **first** segment's `id`. Applied:

- inside `cut(_:range:)`, `setHidden(_:id:_:)` (after hiding), `normalized(_:duration:)` (load, undo/redo snapshots via `applyEdit`, legacy migration output);
- `split` is **not** allowed inside a hidden segment: `canSplit` returns false there and `split` returns `(sorted, nil)`. Accepted cost (owner-approved): partial restore of a cut run = Restore the run → Split → Cut again.
- `setSegments` normalises a single visible full segment back to `[]` (uncut) so "Clear" disables itself when the last mark is removed (*my call*, mirrors `LegacyTrimMigration`).

Consequences: `cutRanges` output is unchanged (it already coalesced), so playback/export are byte-identical. "N cut" in the transport counts hidden runs. Restore-at-playhead on a merged run restores the whole run; the hover preview shows that.

### D2 — Trim collapse

Trim Start = `cut(0 ..< playhead)`; Trim End = `cut(playhead ..< duration)`. With D1 the trimmed side is one hidden segment; no separate merge primitive. "Would it change anything?" stays `cutRanges(after) != cutRanges(before)` — with D1 a hidden run never contains marks, so there is nothing else a trim could change. Existing `trimInsideHiddenRunIsDisabled` behaviour stands.

### D3 — Direct manipulation of marks (owner: popover for every case)

On the segment lane (`StudioWindow.timeline`), each split mark (boundary at `seg.start > 0`) becomes a hit target:

- Hit width: half the distance to each neighbouring mark, capped at 8 pt per side; full 18 pt lane height. Hover: mark thickens and tints accent; pointer cursor. A press on a mark never seeks; a drag that starts on a mark does not scrub (accepted).
- Click → SwiftUI `.popover` anchored to the mark, keyed by the **right-hand segment's `id`** (stable across undo). Dismiss on Esc, click-away, action, or when that id is no longer a boundary (e.g. ⌘Z removed it). Dismiss always clears `hoverAction`.
- Menu by state of (left, right):
  - both visible → one item **Remove split**. Hover preview: the mark drawn as a dashed "will vanish" marker, no coloured range.
  - left visible, right hidden → **Cut the part before (a–b s)** · **Restore the part after (b–c s)**.
  - left hidden, right visible → **Restore the part before (a–b s)** · **Cut the part after (b–c s)**.
  - Item order: the item acting on the left side first. Hovering an item shows the existing red (cut) / green (restore) range preview over that segment.
  - both hidden → cannot occur (D1).
- "Cut …" is disabled (not hidden) with help text "Can't cut the last visible part" when it would hide the last visible segment.
- After "Restore …" both sides are visible and the mark remains (the popover closes; a second click offers Remove split). After "Cut …" D1 merges the mark away.
- Each item is one undo step through the existing `saveEdit` funnel.

Playhead drawn above marks today; marks must stay hoverable under it (playhead gets `allowsHitTesting(false)`).

Opening a mark popover pauses playback (*my call*): the lane auto-scrolls while playing, which would detach an anchored popover. The builder verifies that ⌘Z (app-wide local monitor in `UndoKeyCatcher`) still reaches the editor while the popover is key.

### D4 — Transport glyphs

Cut-at-playhead: `scissors` (visible segment) / `rectangle.badge.plus` (hidden segment, "Restore this segment"). No `eye*` or `arrow.uturn*` glyph in the transport bar.

### D5 — Board

- New `todo` ticket: "[feature] studio: toggle hide/show cut material in the timeline (eye)" — content as drafted in the superseded plan's Task 4 (collapsed view via `TimelineCut.map`, seams, Restore disabled in collapsed mode, absolute unmap for drags).
- Ticket `4nkhM2OIkGko` (CS-0003) goes back to `doing` while this work runs, then `completed`.

## Model additions (names fixed so the plan and tests agree)

- `TimelineSegments.coalescedHidden(_ segments: [TimelineSegment]) -> [TimelineSegment]`
- `TimelineSegments.join(_ segments: [TimelineSegment], atBoundaryOf rightID: UUID) -> [TimelineSegment]` — merge the segment with `id == rightID` into its left neighbour (keeps the left id and the left `hidden` flag); only valid when both flags are equal (returns input unchanged otherwise or when `rightID` is the first segment).
- `CutAction` gains id-carrying cases: `.removeSplit(rightID: UUID)`, `.hideSegmentID(UUID)`, `.restoreSegmentID(UUID)`. `preview(for:…)` ignores `t` for them.
- `CutPreview.Kind` gains `.merge` with `removingSplitAt: Double?`; `CutPreviewOverlay` renders it as the dashed marker only.
- `StudioModel.removeSplit(rightID:)`, `canRemoveSplit(rightID:)`; `hideSegment(_:)` / `restoreSegment(_:)` reused for the two-item cases. `canSplitAtPlayhead` false inside a hidden segment.

## Constraints

- CLT-only toolchain; pinned swift-testing 0.12.0 / KeyboardShortcuts 1.10.0; no `#Preview`.
- `EditState` on-disk format unchanged; old bundles with adjacent hidden segments load (coalesced on `normalized`).
- `TimelineSegment` stays `Equatable` including `id`; every "did it change?" compares against the same materialised list.
- Commits per task on the branch are authorised; no push / merge without asking.

## Left to the builder

- Exact popover layout/padding; whether labels use `%.1f s` or timecode (use whatever the ruler uses).
- Hover highlight colours (reuse `CutPreviewOverlay` palette).
- Where the per-mark hit-rect math lives (a small pure helper is fine, test it).

## Tests the plan must pin

- `coalescedHidden` merges runs, keeps first id, leaves visible runs alone, idempotent.
- `cut`/`setHidden`/`normalized` outputs never contain adjacent hidden segments.
- `split` refused inside hidden; `canSplit` agrees.
- Trim Start over `[0,2)` `[2,4)` `[4,10)` at 6 → `[0,6)h [6,10)`; trim inside a hidden run is a no-op.
- `join` on both-visible merges and keeps left id; refused for mixed flags; `[]` result when the last mark goes.
- `preview(.removeSplit)` → `.merge` with marker; `preview(.hideSegmentID)` nil when it would hide the last visible segment.
- `StudioModel.removeSplit` is one undo step; undo restores the mark.
