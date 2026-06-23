# SRT Subtitle Time Offset — Design

**Date:** 2026-06-23
**Status:** Approved design, pending implementation plan

## Summary

Add a per-track time offset to imported SRT subtitles. The external tool that
generates the `.srt` reads from the **raw, untrimmed** recording, so its cue
timestamps are shifted relative to the trimmed Studio timeline. A single signed
offset (seconds), added to every cue, lets the user re-sync the whole track. A
"Set from playhead" helper computes the offset automatically by aligning the
first cue to the current playhead. The offset is one shared value for the track
(like the shared style): configure once, applies to all cues. It previews live,
persists with the project, and survives a re-import.

## Goals

- One signed offset (seconds) added to every subtitle cue's `begin`/`end`.
- "Set from playhead" computes the offset so cue #1 begins at the playhead.
- Live preview in editor and export; persisted; preserved across re-import.
- Offset is non-destructive — stored cues stay at their raw SRT times.

## Non-Goals (YAGNI)

- Per-cue offsets or retiming individual cues. Cues remain read-only; the offset
  is a single shared value.
- Auto-deriving the offset from the project's `trimIn`. The external generator
  does not know the project trim, so the offset is a manual correction. (`trimIn`
  is unrelated and is not read here.)
- Speed/stretch (rubber-band) retiming. Offset is a pure translation, not a scale.

## Key Decisions

- **Offset stored on `SubtitleTrack`, applied at consumption.** Stored cues stay
  raw; a pure helper shifts + clamps them wherever they are consumed. The offset
  is adjustable live without re-parsing the `.srt`.
- **Signed seconds, added to cue times.** Negative pulls subtitles earlier (the
  trimmed-begin case); positive pushes later. General and direction-agnostic.
- **"Set from playhead" aligns cue #1.** `offset = currentTime - minRawBegin`.
  Cue #1 (smallest raw `begin`) is the standard sync anchor.

---

## Architecture

### 1. Data model — `ProjectBundle/EditState.swift`

`SubtitleTrack` gains one field:

```swift
struct SubtitleTrack: Codable, Equatable {
    var srtFilename: String
    var style: SubtitleStyle
    var cues: [SubtitleCue]
    var offset: Double            // seconds, added to every cue's begin/end
    // ...
}
```

- Memberwise init gains `offset: Double = 0` (last param, default `0`).
- Custom `init(from:)` decodes `offset = try c.decodeIfPresent(Double.self,
  forKey: .offset) ?? 0`, mirroring the existing forward-compat pattern — legacy
  projects without the field load as `0`.
- `CodingKeys` gains `offset`. `Equatable` is synthesized.
- `schemaVersion` stays `1` (additive optional field, no migration).

### 2. Pure math — `Studio/SubtitleTimeline.swift`

Generalize the existing `clamped(_:duration:)` into an offset-aware version:

```swift
/// Shift every cue by `offset` seconds, then drop cues that fall entirely
/// outside [0, duration) and clamp the survivors to that range. Preserves order.
/// `offset == 0` reproduces the previous `clamped` behavior.
static func effective(_ cues: [SubtitleCue], offset: Double, duration: Double) -> [SubtitleCue] {
    cues.compactMap { cue in
        let begin = cue.begin + offset
        let end = cue.end + offset
        guard end > 0, begin < duration else { return nil }
        var c = cue
        c.begin = max(0, begin)
        c.end = min(end, duration)
        return c
    }
}
```

- A cue shifted fully past `duration` (`begin + offset >= duration`) or fully
  before `0` (`end + offset <= 0`) is dropped.
- A cue straddling an edge is clamped: `begin` to `≥ 0`, `end` to `≤ duration`.
- The old `clamped(_:duration:)` is removed; its one call site and its unit test
  move to `effective(_, offset: 0, duration:)`.
- `active(at:cues:)` and `subRows(_:)` are unchanged — they operate on whatever
  cue list they are handed (now the already-shifted list).

### 3. Storage + consumption — `Studio/StudioModel.swift`

**Store raw cues.** Today `load()` and `importSubtitles(from:)` bake the
duration clamp into the stored cues. Change both to store the **raw** parsed
cues plus the `offset`; the clamp moves to consumption.

- `importSubtitles(from:)`: parse to `parsed`. Validity check uses
  `SubtitleTimeline.effective(parsed, offset: preservedOffset, duration:)` —
  if empty, fail (delete file, surface error, state → idle) exactly as before.
  On success store `SubtitleTrack(srtFilename:, style: preservedStyle, cues:
  parsed, offset: preservedOffset)`. `preservedOffset` = the prior track's
  offset on re-import, else `0`.
- `load()`: build the track from `edit.subtitles` with raw `track.cues` and
  `track.offset`. Collapse to `nil` when `effective(track.cues, offset:
  track.offset, duration:)` is empty (parallels today's "no surviving cues →
  no track").

**Single shift point.** New computed property:

```swift
var effectiveSubtitleCues: [SubtitleCue] {
    guard let s = subtitles else { return [] }
    return SubtitleTimeline.effective(s.cues, offset: s.offset, duration: duration)
}
```

The three consumers switch from `subtitles?.cues` to `effectiveSubtitleCues`:
- compositor spec build (`StudioModel.swift` ~:1523) — `SubtitleTimelineSpec(style:
  track.style, cues: effectiveSubtitleCues)`.
- `SubtitleTimelineLane.swift` (~:17) — `cues` reads `model.effectiveSubtitleCues`.
- `SubtitleCanvasOverlay.swift` (~:52) — `activeCue` scans `model.effectiveSubtitleCues`.

`showsSubtitleTimeline` continues to gate on the raw `subtitles.cues` being
non-empty, so the lane (and thus the offset control's reachability via the
toolbar popover) stays available while the user dials the offset in.

**Setters.**

```swift
func setSubtitleOffset(_ v: Double) {
    guard subtitles != nil else { return }
    subtitles!.offset = min(max(-86_400, v), 86_400)   // finite guard; ±24h
    applyVideoComposition()                            // same recomposite call as the style setters
    saveEdit()
}

func setSubtitleOffsetFromPlayhead() {
    guard let cues = subtitles?.cues, let minBegin = cues.map(\.begin).min() else { return }
    setSubtitleOffset(currentTime - minBegin)
}
```

- The `[-86_400, 86_400]` clamp is only a finite guard against pathological
  input; it is intentionally **not** tied to `duration`, because the trimmed
  portion can exceed the (short) trimmed clip length, requiring a large offset.
- `applyVideoComposition()` is the same recompose call the existing subtitle
  style setters use (see `updateSubtitleStyle`) — it refreshes the current frame.

### 4. UI — `Studio/StudioWindow.swift`

In `subtitleStylePopover` (~:741), add a "Time offset" row at the top, above the
style controls:

- A numeric `TextField` + `Stepper` showing the offset in seconds (0.1 s step,
  2-decimal format), bound through `model.setSubtitleOffset`. Reading the current
  value from `model.subtitles?.offset ?? 0`.
- A "Set from playhead" `Button` → `model.setSubtitleOffsetFromPlayhead()`.
- Both disabled while `model.subtitleState != .idle`.

Style and offset both live in the same popover, reinforcing "configure the track
once." No new toolbar affordance.

### 5. Edge cases

- **All cues shifted off-screen.** `effectiveSubtitleCues` is empty, so nothing
  renders and the canvas overlay shows no box; the lane strip is empty but the
  track still exists (raw cues non-empty), so the popover and "Set from playhead"
  remain reachable to recover. On project reopen, an offset that leaves zero
  surviving cues collapses the track to `nil` (same rule as today) — a degenerate
  config, matching existing behavior.
- **No cues.** `setSubtitleOffsetFromPlayhead()` is a no-op.
- **Re-import.** Offset is preserved alongside style (both carried from the prior
  track), so a corrected-text re-import keeps the user's sync.
- **Export.** Export reuses the compositor, which renders the shifted cues, so the
  offset burns into the exported video with no extra export code.
- **Z-order.** Unchanged — subtitles still composite below manual text blocks.

## Testing

swift-testing, pure helpers only (capture/UI glue is not unit-tested):

- **`SubtitleTimeline.effective`:** positive offset shifts cues later; negative
  shifts earlier; a cue shifted fully past `duration` is dropped; a cue shifted
  fully before `0` is dropped; a cue straddling `0` clamps `begin` to `0`; a cue
  straddling `duration` clamps `end` to `duration`; `offset: 0` reproduces the
  former `clamped` behavior (port the existing clamp test).
- **`EditState` Codable round-trip:** a track with a non-zero `offset` round-trips;
  legacy JSON lacking the `offset` field decodes to `0`.

`setSubtitleOffsetFromPlayhead` and the UI binding are model/UI glue and are not
unit-tested, per project convention.

## New / touched files

- `ProjectBundle/EditState.swift` — `SubtitleTrack.offset`, init + decoder + key.
- `Studio/SubtitleTimeline.swift` — replace `clamped` with `effective`.
- `Studio/StudioModel.swift` — store raw cues, `effectiveSubtitleCues`,
  `setSubtitleOffset`, `setSubtitleOffsetFromPlayhead`, route consumers + load +
  import through the new helper.
- `Studio/StudioWindow.swift` — offset row in `subtitleStylePopover`.
- `Studio/SubtitleTimelineLane.swift` — read `effectiveSubtitleCues`.
- `Studio/SubtitleCanvasOverlay.swift` — read `effectiveSubtitleCues`.
- `Tests/CaptureStudioTests/` — `effective` tests; `EditState` offset round-trip.
