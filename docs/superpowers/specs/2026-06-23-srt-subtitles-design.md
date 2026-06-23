# SRT Subtitle Support — Design

**Date:** 2026-06-23
**Status:** Approved design, pending implementation plan

## Summary

Let a user import an `.srt` file into a Capture Studio project to overlay subtitles
on the video. Subtitles live in their own timeline lane, separate from text blocks.
Cues (text + timing) are **read-only**, driven entirely by the SRT. The user
configures styling, position, and size **once** for the whole track; that config
applies to every cue. The user can remove the `.srt`, which deletes the subtitles
and hides the lane. Add and remove both show a loader.

## Goals

- Import a `.srt`; render its cues as styled subtitle overlays in preview and export.
- One shared, one-time style/position/size configuration applied to all cues.
- Subtitles in a dedicated lane, independent of the text-block timeline.
- Remove the `.srt` to clear subtitles and hide the lane.
- Loader shown while applying (import) and removing.

## Non-Goals (YAGNI)

- Editing individual cue text or timing after import. Cues are read-only; to change
  wording, the user edits the `.srt` and re-imports.
- Per-cue style overrides. Style is a single shared config.
- Multiple simultaneous subtitle tracks. One track per project.
- Other subtitle formats (`.vtt`, `.ass`). SRT only.

## Key Decisions

- **Read-only cues.** SRT is the source of truth for text and timing.
- **`.srt` copied into the bundle** (like `background.png`) so the project stays
  self-contained; the parsed cues are also persisted for fast load.
- **Approach A — separate `SubtitleTrack`** (shared style + lightweight cues),
  not reusing the `textBlocks` array. Clean separation, single style source,
  reuses the existing renderer.

---

## Architecture

### 1. Data model

New types in `Sources/CaptureStudio/ProjectBundle/EditState.swift`, mirroring the
style fields of `TextBlock`.

```swift
struct SubtitleStyle: Codable, Equatable {
    // copied from TextBlock — the one-time shared config
    var centerX: Double = 0.5
    var centerY: Double = 0.85
    var fontName: String = "Helvetica"
    var fontSize: Double = 0.05          // fraction of canvas height
    var fontWeight: TextWeight = .semibold
    var colorHex: String = "#FFFFFF"
    var alignment: TextAlignmentH = .center
    var strokeWidth: Double = 0
    var strokeHex: String = "#000000"
    var boxEnabled: Bool = false
    var boxHex: String = "#000000"
    var boxOpacity: Double = 0.5
    var shadow: Bool = true
}

struct SubtitleCue: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double                    // seconds, timeline space
    var end: Double                      // half-open [begin, end)
    var text: String                     // read-only
}

struct SubtitleTrack: Codable, Equatable {
    var srtFilename: String              // file copied into bundle, e.g. "subtitles.srt"
    var style: SubtitleStyle = .init()
    var cues: [SubtitleCue] = []
}
```

`EditState` gains:

```swift
var subtitles: SubtitleTrack?            // nil = no subtitles, lane hidden
```

`EditState`'s custom `init(from:)` defaults `subtitles` to `nil` for forward
compatibility — old projects without the field load clean. `SubtitleStyle`,
`SubtitleCue`, and `SubtitleTrack` reuse the existing `TextWeight` /
`TextAlignmentH` enums. `schemaVersion` stays `1` (additive optional field, no
migration).

### 2. SRT parser

New `Sources/CaptureStudio/Studio/SubtitleParser.swift` — pure, unit-testable.

```swift
enum SubtitleParser {
    static func parse(_ raw: String) -> [SubtitleCue]
}
```

- Normalize line endings (`\r\n` → `\n`), strip a leading BOM.
- Split on blank lines into blocks. Each block: optional index line /
  `HH:MM:SS,mmm --> HH:MM:SS,mmm` timestamp line / one or more text lines.
- Parse timestamps (comma decimal separator) → seconds. Join multi-line cue text
  with `\n`. Strip simple inline tags (`<i>`, `<b>`, `</i>`, `</b>`) to plain text.
- Skip malformed blocks (missing/unparseable timestamp line). A block missing only
  the index line is still accepted.
- Assign a fresh `UUID` per cue.

**Timeline alignment:** SRT cue times are absolute from media start (00:00).
Timeline space matches the recording start, so cue seconds map 1:1 — no offset.

### 3. Import / remove flow + loader

New model state on `StudioModel`:

```swift
enum SubtitleState: Equatable { case idle, applying, removing }
@Published private(set) var subtitleState: SubtitleState = .idle
@Published var subtitleSelected: Bool = false
```

**Entry point.** "Import subtitles (.srt)…" action using `NSOpenPanel`
(`allowedContentTypes` = the SRT `UTType` if resolvable, else `.text`), mirroring
`pickBackgroundImage` in `StudioWindow.swift`. Shown in the same controls area as
the background-image picker when no subtitle track exists.

**Apply.** `model.importSubtitles(from url: URL)`:
1. Set `subtitleState = .applying`.
2. Off-main `Task`: copy the file into the bundle via new
   `bundle.writeSubtitleFile(from:)` (returns `"subtitles.srt"`), read + parse it.
3. Build `SubtitleTrack`. On re-import over an existing track, **preserve the
   existing `style`** and replace `cues` + file; otherwise default style.
4. Back on main: drop cues with `begin >= duration`, clamp `end` to duration.
   If zero valid cues remain, surface an error, leave `subtitles` unchanged, set
   `subtitleState = .idle`, and stop.
5. Set `subtitles`, recomposite (warming the text cache), `saveEdit()`,
   `subtitleState = .idle`.

**Remove.** `model.removeSubtitles()`:
1. Set `subtitleState = .removing`.
2. Delete the bundle `.srt` file, set `subtitles = nil`, clear `subtitleSelected`,
   recomposite, `saveEdit()`, `subtitleState = .idle`. Lane hides.

**Bundle utilities** in `ProjectBundle` (alongside `writeBackgroundImage`):

```swift
func writeSubtitleFile(from source: URL) throws -> String   // copy → "subtitles.srt"
func deleteSubtitleFile()
```

**Loader.** `subtitleState` drives a small `ProgressView` overlay on the subtitle
lane / canvas region for both `.applying` and `.removing`. Work runs async so the
UI never blocks even though parsing is fast.

### 4. Compositor integration

`CompositorLayout` (in `CameraCompositor.swift`) gains:

```swift
struct SubtitleSpec { var style: SubtitleStyle; var cues: [SubtitleCue] }
var subtitles: SubtitleSpec?
```

In `startRequest`, **before** the text-blocks loop (so manual text sits on top of
subtitles), composite the active cues:

```swift
if let sub = layout.subtitles {
    for cue in activeCues(at: now, cues: sub.cues) {
        let block = sub.style.asTextBlock(begin: cue.begin, end: cue.end, text: cue.text)
        if let img = textImage(block, canvas: layout.canvas) {
            output = img.composited(over: output)
        }
    }
}
```

`SubtitleStyle.asTextBlock(begin:end:text:)` synthesizes a transient `TextBlock`
from the shared style + cue. The existing `TextImageRenderer` and `textCache` are
reused unchanged — the cache key already covers all style fields plus text and
canvas size, so synthesized blocks cache and dedupe correctly.

`activeCues(at:cues:)` returns cues whose half-open `[begin, end)` span contains
`now`. Overlapping cues (rare in SRT) all render; same-position overlap stacks
visually — accepted as a known minor limitation.

### 5. Subtitle lane UI (read-only)

New `Sources/CaptureStudio/Studio/SubtitleTimelineLane.swift`, sibling to
`TextTimelineLane`, rendered only when `model.subtitles != nil`.

- Cue spans on a single row (subtitles rarely overlap; if they do, reuse the
  `subRows` greedy-packing helper used by the text lane).
- Cue blocks show truncated text. **Non-draggable, no edge handles** (read-only).
- Tap a cue → seek the playhead into its span (frame-aligned), set
  `subtitleSelected = true` (clearing camera/text selection), open the subtitle
  config inspector.
- Playhead line across the row; empty-area scrub-to-seek, same as the text lane.
- Lane header: "Subtitles" label. While `subtitleState != .idle`, a `ProgressView`
  overlay covers the lane.

### 6. Config inspector + canvas interaction

One shared config; edits write to `subtitles.style` and re-render all cues.

- **Inspector.** A "Subtitles" section reusing the text style control widgets
  (font, size, weight, color, alignment, stroke, box, shadow), bound to new
  `model.setSubtitle*` setters that mutate `subtitles.style`, recomposite, and
  `saveEdit()`. Includes a **Remove subtitles** button. Shown when
  `subtitleSelected`.
- **Selection model.** Extend the existing camera-XOR-text mutual exclusion to
  include subtitles via `subtitleSelected`. Selecting subtitles clears camera and
  text selection; selecting camera/text clears `subtitleSelected`.
- **Position (canvas).** The cue active at the playhead renders a draggable
  `SubtitleCanvasOverlay` (mirrors `TextCanvasOverlay`) when `subtitleSelected`.
  Dragging updates `style.centerX/centerY` → applies to **all** cues. If the
  playhead is in a gap (no active cue), the inspector hints the user to scrub to a
  cue to reposition; size/style controls still work.
- **Size.** Via the inspector `fontSize` slider (matches text — text has no canvas
  resize handle either).

### 7. Edge cases

- **Single track.** Re-importing replaces the file + cues; **preserves the existing
  `style`** so a user's config survives a corrected-text re-import.
- **Malformed / empty SRT.** Zero valid cues → no track created, error surfaced,
  state returns to idle.
- **Cues beyond duration.** Drop cues with `begin >= duration`; clamp `end` to
  duration.
- **Empty-text or zero-length cue (`begin == end`).** Inert, skipped (matches
  `TextBlock` behavior).
- **Z-order.** Subtitles composite under text blocks (manual annotations on top),
  both above camera/cursor/background.
- **Export.** Export reuses the same composition builder, so subtitles burn into
  the exported video automatically — no extra export code.

## Testing

swift-testing, pure helpers only (per project convention — capture/UI glue is not
unit-tested):

- **`SubtitleParser.parse`:** well-formed multi-cue input; multi-line cue text;
  `\r\n` line endings; leading BOM; comma decimal timestamps; block missing the
  index line (accepted); malformed block (skipped); empty input (`[]`); inline tag
  stripping.
- **`activeCues(at:cues:)`:** half-open boundary behavior (`begin` inclusive, `end`
  exclusive); overlapping cues; gaps between cues.
- **Cue clamp/drop vs duration.**
- **`SubtitleStyle.asTextBlock`:** every style field maps to the right `TextBlock`
  field; `begin`/`end`/`text` carried through.
- **`EditState` Codable round-trip:** with `subtitles` present and `nil`;
  forward-compat decode of legacy JSON lacking the `subtitles` field → `nil`.

## New / touched files

- `ProjectBundle/EditState.swift` — new types, `EditState.subtitles`, bundle
  subtitle file read/write/delete utilities.
- `Studio/SubtitleParser.swift` — new, SRT → cues.
- `Studio/StudioModel.swift` — `subtitleState`, `subtitleSelected`, import/remove,
  style setters, selection wiring, compositor spec plumbing.
- `Studio/CameraCompositor.swift` — `SubtitleSpec`, `CompositorLayout.subtitles`,
  composite loop, `SubtitleStyle.asTextBlock`, `activeCues`.
- `Studio/SubtitleTimelineLane.swift` — new, read-only lane.
- `Studio/SubtitleCanvasOverlay.swift` — new, draggable position overlay.
- `Studio/StudioWindow.swift` — import button, inspector "Subtitles" section,
  lane mounting, loader overlay.
- `Tests/CaptureStudioTests/` — parser, active-cue, clamp, mapping, Codable tests.
