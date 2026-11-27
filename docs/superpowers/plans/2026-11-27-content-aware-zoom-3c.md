# Content-aware zoom, part 3c (frame differencing) — implementation plan

Spec: `docs/superpowers/specs/2026-11-27-content-aware-zoom-design.md`
(sections "Shared model" and "3c"). Parts 3a/3b get their own plans later.

Branch `t3/smooth-auto-zoom-pan`. Every task: tests first for the pure part,
`swift test` green, and at the end
`DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test`.

Existing code this builds on:

- `Studio/ZoomShotPlanner.swift` — `shots(...)`, `planSegment`, local `settle`.
- `Studio/AutoZoom.swift` — `AutoZoomConfig`, `AutoZoomTrack.build/appendRun`.
- `Studio/AutoZoomSuggester.swift` — `suggest(...)`, `splits` from scrolls.
- `Studio/ZoomActivity.swift` — `TimeSpan`, `ZoomActivity`.
- `Studio/StudioModel.swift` — `withCollapsedTimeline`, `zoomTrackConfig`,
  `generateAutoZoom(scope:)`, `clickSamples`, `cursorSamples`.
- `Studio/Inspector/ZoomInspector.swift` — "Auto zoom" button.
- `ProjectBundle/ProjectBundle.swift` — bundle file URLs.

## Task 1 — Change events (pure)

New `Studio/ContentChanges.swift`:

```swift
/// Pixels inside `rect` changed between `t0` and `t1` (master seconds).
struct ChangeEvent: Codable, Equatable {
    var t0: Double
    var t1: Double
    /// Bounding box of the changed cells, normalized 0…1 of the source.
    var x: Double, y: Double, w: Double, h: Double
    /// Changed cells ÷ all cells (union over the event).
    var coverage: Double
    /// Changed cells ÷ cells in the bounding box (union over the event).
    var density: Double
}
```

Normalized rects (like `ZoomBlock.focusX/Y`) so the cache does not depend on
the analysis resolution.

`enum LumaDiff` — `changedCells(previous:current:width:height:cell:threshold:minPixels:) -> CellMask`
where `CellMask { cols, rows, bits: [Bool] }`. A cell is changed when at least
`minPixels` of its pixels differ by more than `threshold`.

`struct ChangeGrouper` — `mutating func add(t: Double, mask: CellMask)` and
`mutating func finish() -> [ChangeEvent]`:

- a frame with no changed cells is ignored;
- frames with change closer than `joinGap` (0.25 s) extend the open event and
  OR into its union mask; otherwise the open event closes;
- an open event older than `maxLength` (2 s) closes and a new one starts;
- on close, drop: a single-frame event of a single cell; an event whose box is
  a strip (one side ≤ 1 cell and the other ≥ 60% of the grid).

Tests (`ContentChangesTests.swift`): identical frames → empty mask; a changed
block of pixels → exactly the covering cells; sub-threshold noise → empty;
grouping/joining/splitting by time; the two discard rules; coverage and
density values; normalized rect of a known cell box.

## Task 2 — Hints for the planner and suggester (pure)

Same file:

```swift
/// What the planner / suggester need, derived from change events.
struct ContentHints: Equatable {
    var changes: [ChangeEvent] = []
    static let none = ContentHints()

    /// Changes mapped onto the cut timeline (events inside a cut are dropped,
    /// events straddling one are clipped), for use inside withCollapsedTimeline.
    func collapsed(cuts: [Range<Double>]) -> ContentHints

    /// Spans where the whole picture redraws: coverage ≥ wideCoverage (0.4) and
    /// (length ≥ 0.5 s, or merged with neighbours closer than 0.25 s to reach it).
    func wideSpans() -> [TimeSpan]

    /// For each click: the first change that starts in [click.t, click.t + 1.0],
    /// is dense (density ≥ 0.3), is not wide (coverage < wideCoverage) and lies
    /// within 0.25 of the source width of the click point. → what the click
    /// opened. Rects in source pixels.
    func revealed(by clicks: [ClickSample], sourceSize: CGSize) -> [Reveal]
}

struct Reveal: Equatable { var t: Double; var click: CGPoint; var rect: CGRect }
```

Tests: collapse across cuts; wide detection incl. merge; reveal matching
(in window / too late / too far / too sparse / wide → no reveal).

## Task 3 — Aim leaning in the shot planner (pure)

`ZoomShotPlanner`:

- `settle` returns the pointer bounding box and the time span it covers, not
  just the centre.
- New parameter on `shots(...)`:
  `lean: ((_ from: Double, _ to: Double) -> CGRect?)? = nil` — the content rect
  relevant to a shot whose settled span is `[from, to]`.
- New pure helper:

```swift
/// Move `box`'s centre toward `target`'s centre as far as possible while `box`
/// stays inside the safe zone (half-size safeW × safeH) around the result.
static func leanedAim(box: CGRect, toward target: CGRect, safeW: Double, safeH: Double) -> CGPoint
```

  `aim.x = clamp(target.midX, box.maxX − safeW, box.minX + safeW)`; when the
  box is wider than the safe zone on an axis (cannot happen via `settle`, but
  guard), keep the box centre on that axis.
- Applied where a shot's aim is set from `settle` (segment start without a
  carried-in `start`, and after each real exit). A carried-in aim is unchanged.
- `lean == nil` or returning nil → bit-identical to today (existing tests stay
  untouched and must pass unchanged).

`AutoZoomTrack` / `AutoZoomConfig`:

- `AutoZoomConfig.reveals: [Reveal] = []` (already on the track's timeline).
- In `appendRun`, per follow block build the `lean` closure: reveals with
  `t` in `[from, to]`, whose rect fits the block's view (`w ≤ 2·half.w`,
  `h ≤ 2·half.h`); take them in time order, growing a union while the union
  still fits the view; return the union (nil if none).

Tests: `leanedAim` (fits → centred on union; too far → pointer box pinned at
the safe-zone edge; degenerate box); planner with a lean closure keeps the
pointer inside the safe zone for the whole shot; `AutoZoomTrack` with one
reveal to the right of a click frames further right than without, and the
pointer stays within the hard margin at every keyframe; no reveals → track
equals the no-hint track exactly.

## Task 4 — Suggester: stay wide, pick a scale (pure)

`AutoZoomSuggester.suggest` gains `hints: ContentHints = .none` and
`reveals: [Reveal] = []`; `AutoZoomSuggestConfig` gains
`viewSize: CGSize?` (source px visible at 1×), `minScale = 1.5`,
`maxScale = 3.0`, `subjectPad = 0.15`.

- `hints.wideSpans()` (master time → collapsed like scrolls) are appended to
  `splits`. Unlike scroll bursts they have no minimum length beyond what
  `wideSpans` already enforces.
- Scale: for each emitted follow block, the subject is the union of the click
  points and reveal rects inside the block's span. With `viewSize` set and a
  subject of non-zero area on at least one axis (≥ 2 clicks or ≥ 1 reveal):
  `fit = min(view.w / (subject.w·(1+2·pad)), view.h / (subject.h·(1+2·pad)))`,
  `scale = clamp(fit, minScale, maxScale)`, rounded to 0.05. Otherwise nil.
  Manual (typing) blocks keep nil.
- This applies only when hints are present (`!hints.changes.isEmpty`), so the
  Phase 2 output is unchanged for an unanalysed recording.

Tests: a wide span between two click clusters splits them and no block covers
it; scale for a tight subject is `maxScale`, for a spread one `minScale`, in
between matches the formula; no hints → blocks equal today's output.

## Task 5 — Analyzer (AVFoundation glue)

New `Studio/ChangeAnalyzer.swift`:

```swift
enum ChangeAnalyzer {
    /// Decode `url`'s video at low resolution and group what changed.
    /// `progress` is called with 0…1 on an arbitrary thread. Throws
    /// CancellationError when the task is cancelled.
    static func analyze(url: URL, progress: @Sendable (Double) -> Void) async throws -> ChangeAnalysis
}

struct ChangeAnalysis: Codable, Equatable {
    static let currentVersion = 1
    var version: Int
    var duration: Double
    var width: Int, height: Int       // source pixels
    var events: [ChangeEvent]
}
```

- `AVAssetReader` + `AVAssetReaderTrackOutput`, 420v, width 192, height by
  aspect; luma plane only; `alwaysCopiesSampleData = false`.
- Frame time = presentation timestamp minus the track's start (the same time
  base the composition uses for the screen track — verify against how
  `StudioModel` inserts the screen track; apply the same offset).
- Check `Task.isCancelled` each frame; `reader.cancelReading()` on cancel.
- Tuning step: run on the user's recordings in `~/Movies/Capture Studio/`,
  print events next to click times, and adjust `threshold`, `minPixels`,
  `joinGap`, density / coverage limits until menus and popovers that follow
  clicks show up as reveals and page changes as wide spans.

Cache: `ProjectBundle.changesURL` = `analysis/changes.json`;
`loadChanges() -> ChangeAnalysis?` (nil when missing, unreadable, wrong
version, or duration/size mismatch beyond 0.1 s / exact size) and
`writeChanges(_:)` (creates the directory, atomic). Test the round trip and
the rejection cases in `EditStateTests`-style bundle tests.

## Task 6 — Model and UI

`StudioModel`:

- `private(set) var contentHints = ContentHints.none`; loaded from the cache
  with the project (where `zoomActivity` is loaded).
- `@Published private(set) var autoZoomAnalysisProgress: Double?` (nil = idle).
- `func runAutoZoom(scope:) async -> Bool`: if no analysis is loaded, run
  `ChangeAnalyzer.analyze` in a stored `Task` (off the main actor), publish
  progress (throttled to the main actor), write the cache, set
  `contentHints`; on cancel or failure continue without hints. Then call the
  existing generation with hints, `reveals` and `viewSize`.
- `func cancelAutoZoomAnalysis()`.
- A second call while one is running is ignored. Closing the Studio window
  cancels the task.
- `zoomTrackConfig(canvas:)` sets `config.reveals` from
  `contentHints.collapsed(cuts:)` + the (already collapsed) `clickSamples`
  when running inside `withCollapsedTimeline`, else from the master-time
  values. The view size used by the suggester is the one `zoomTrackConfig`
  computes for the current canvas.
- After analysis completes, `applyVideoComposition()` so existing follow
  blocks pick up the hints.

`ZoomInspector`: while `autoZoomAnalysisProgress != nil` the Auto zoom button
is replaced by a progress row ("Analysing video… 42%") with a Cancel button.
The scope dialog is asked before analysis starts.

## Task 7 — Verify

- `swift test` on Xcode and CLT.
- Build the app, run Auto zoom on two existing recordings, check: analysis
  progress and cancel, cache file written, second run instant, blocks have
  scales, no crash on a camera-main bundle (button disabled as today).
- Code review pass on the diff.

## Out of scope here

- `window`, `element`, `caret` hints (3a/3b) and reach bounding by window.
- Content-triggered moves without the pointer.
- Analysing only parts of the file.

## Scrutiny outcome (2026-11-27)

The plan above was reviewed against the code before implementation. All
blockers and majors were accepted; the resulting rules are recorded in the
spec's "Revision — 3c as built" section and supersede Tasks 2–6 where they
differ (reveals paired in master time, spatial grouping with splits at
mouse-downs, lean slack, wide moments as walls, one reveal-based scale per run,
cache keyed on the video's byte size, no overwrite of edits made during
analysis).
