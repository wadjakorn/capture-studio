# Content-aware zoom, part 3a (window frames) — implementation plan

Spec: `docs/superpowers/specs/2026-11-27-content-aware-zoom-design.md`
(sections "Use 2–4", "3a" and "Revision — 3c as built"). Part 3b gets its own
plan later.

Branch `t3/smooth-auto-zoom-pan` (continues from `d7ed3c5`). Every task: tests
first for the pure part, `swift test` green, and at the end
`DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test`.

Existing code this builds on:

- `Recorder/EventTracker.swift` — in-memory events, host-clock stamps, written
  at finalize relative to the screen anchor.
- `Recorder/RecordingSession.swift` — `eventTracker.start()` (display main
  only), `stopAndWrite`, two `cancel()` sites.
- `Recorder/CaptureContentWindows.swift` — `snapshot` of our content windows.
- `Studio/CursorOverlay.swift` — `sourcePoint(x:y:display:sourceSize:)`.
- `Studio/ZoomShotPlanner.swift` — `shots(...)`, `planSegment`, `settle`,
  `clamp(_:toReach:)`.
- `Studio/AutoZoom.swift` — `AutoZoomConfig`, `appendRun`, `geometry`.
- `Studio/AutoZoomSuggester.swift` — one scale per run from reveals.
- `Studio/StudioModel.swift` — `loadOverlayData`, `withCollapsedTimeline`,
  `zoomTrackConfig`, `generateAutoZoom`.

Measured: `CGWindowListCopyWindowInfo(.optionOnScreenOnly | .excludeDesktopElements)`
with 40 windows takes ~0.5 ms warm (48 ms on the very first call).

## Task 1 — File format (pure)

New `ProjectBundle/Windows.swift`:

```swift
/// One line of windows.jsonl: from `t` on, this window is the active one.
/// `t` is seconds relative to the screen track's sessionStartHostTime; the
/// frame is in global screen points, top-left origin (same space as
/// events.jsonl). `id == 0` with a zero size means "no active window".
struct WindowLine: Codable, Equatable {
    var t: Double
    var id: Int
    var x: Double, y: Double, w: Double, h: Double
}
enum WindowsCodec { encodeLines / decodeLines }   // like EventsCodec; bad lines skipped
```

`ProjectBundle.windowsURL` = `windows.jsonl`.

Deviation from the spec: no `app` field. Nothing uses it, and the less the file
says about what was on screen the better.

Tests: round trip; malformed lines skipped; empty data → [].

## Task 2 — Recording (pure core + glue)

New `Recorder/WindowTracker.swift`.

Pure, tested:

```swift
struct WindowCandidate: Equatable { var id: Int; var pid: Int32; var layer: Int
                                    var alpha: Double; var frame: CGRect }
enum ActiveWindow {
    /// `candidates` front to back. The first layer-0, visible (alpha > 0),
    /// at least 50×50 pt window owned by `frontPID`. One of our own windows
    /// counts only when it is a registered content window.
    static func pick(_ candidates: [WindowCandidate], frontPID: Int32,
                     ownPID: Int32, contentIDs: Set<Int>) -> WindowCandidate?
}
/// Keeps a line only when the active window or its frame (≥ 1 pt) changed.
struct WindowLog { mutating func note(hostTime: Double, window: WindowCandidate?)
                   var entries: [(hostTime: Double, line: WindowLine)] }
```

Glue (`@MainActor final class WindowTracker`, not unit-tested):

- `start()`: 4 Hz `Timer` in `.common` mode; an
  `NSWorkspace.didActivateApplicationNotification` observer that samples at
  once (app switches are stamped when they happen). First sample is taken by
  the timer, not inside `start()`, so the cold 48 ms call does not sit in
  `beginRecording`.
- A sample: front pid from `NSWorkspace.shared.frontmostApplication`, the
  window list from `CGWindowListCopyWindowInfo`, content IDs from
  `CaptureContentWindows.shared.snapshot` (visible window numbers + sheets),
  → `ActiveWindow.pick` → `WindowLog.note`. Only number, layer, alpha, owner
  pid and bounds are read; the name key is never touched.
- `stopAndWrite(to:screenAnchorHostTime:)`: lines with `t` relative to the
  anchor (4 decimals), atomic write; nothing written when there are no lines.
  `cancel()`.

`RecordingSession`: start next to `eventTracker.start()` (display main only);
`try? windowTracker.stopAndWrite(...)` after the events are written (failure is
silent: no hint); `cancel()` at both existing `eventTracker.cancel()` sites.

Deviation from the spec: no extra sample on mouse-down. At a mouse-down the
clicked window is not active yet; the next tick (≤ 250 ms) or the app-activate
notification records it. A late window change costs nothing in the planner: a
pointer outside the stale window is simply not bound to it.

Tests: pick (front app's first layer-0 window; skips other pids, layers ≠ 0,
alpha 0, tiny; own chrome skipped, own content window accepted; none → nil);
log (unchanged → one line; moved → new line; window → none → window).

## Task 3 — Window spans in the Studio (pure)

New `Studio/WindowHints.swift`:

```swift
/// The active window between `begin` and `end`, in source pixels, clipped to
/// the source.
struct WindowSpan: Equatable { var begin: Double; var end: Double; var rect: CGRect }

enum WindowHints {
    static func spans(lines: [WindowLine], display: DisplayInfo, sourceSize: CGSize,
                      duration: Double) -> [WindowSpan]
    static func collapsed(_ spans: [WindowSpan], cuts: [Range<Double>]) -> [WindowSpan]
    static func window(at t: Double, in spans: [WindowSpan]) -> CGRect?
}
```

`spans` rules (each line holds until the next; clamped to `0…duration`):

- frame → source pixels via `CursorOverlay.sourcePoint`, clipped to the source;
- no span for: a "none" line; a window with less than 25% of its own area
  inside the source (mostly outside an area capture); a clipped window covering
  at least 85% of the source (full screen / maximized: nothing to bound);
- consecutive lines of the same window whose four edges all stay within 1% of
  the source width of the span's rect are the same span (jitter);
- a span shorter than 0.6 s is dropped — the window is being moved or resized,
  and a bound that changes four times a second would make the camera chase it.

`collapsed`: `TimelineCut.span` per span (a span straddling a cut continues;
one wholly inside a cut is dropped). `window(at:)`: binary search, `begin ≤ t < end`.

Tests: mapping incl. an area capture's shifted origin and Retina scale;
each of the four rules; collapse across cuts; lookup at edges and in gaps.

## Task 4 — Bound in the shot planner (pure)

`ZoomShotPlanner`:

```swift
/// Margin kept around a bounding window, as a fraction of the view per side.
/// Above 1 − hardMargin (4%), so a pointer on the window's edge is still
/// inside the hard margin.
static let boundMargin = 0.05

/// `reach` narrowed so the view stays inside `window` grown by the margin.
/// Per axis: an inverted base axis is kept; a window smaller than the view
/// centres on the window (clamped into the base reach).
static func boundedReach(_ reach: CGRect, to window: CGRect, half: CGSize) -> CGRect
```

`shots(...)` gains `bound: ((Double) -> CGRect?)? = nil` (the window, source
px, at a time) and `resettle: [Double] = []` (times the window changes).

In `planSegment`:

- Each shot carries its bound. `settle(k0)` takes the window at `time(k0)`;
  the shot is bound to it only when the settled pointer box lies inside it
  (edge tolerance). The shot's reach is then `boundedReach(reach, to:, half:)`
  — used for `center` and for the lean goal. Unbound → today's reach.
- A carried-in `start` aim is bound by the window at `begin` when the pointer
  is inside it.
- A bound shot also ends when the pointer leaves the window (same grace rule;
  during the grace the pointer must stay inside the hard margin of the shot's
  **centre**, since the bound can put the centre away from the aim).
- At a `resettle` time reached while holding, the shot re-settles from that
  step: a different centre becomes a new shot with `tExit == tArrive ==` that
  time (an ordinary eased move, not a cut); the same centre just adopts the
  new aim and bound. Resettle times passed during a flight are consumed — the
  landing already settles against the window of its own time.
- `bound == nil` and `resettle.isEmpty` → bit-identical to today (existing
  tests untouched and passing).

`AutoZoomConfig.windows: [WindowSpan] = []` (on the track's timeline). In
`appendRun`, for follow blocks when it is not empty: `bound` = the window at
`t` intersected with the block's `cursorBounds` (nil when empty); `resettle` =
the begin of every span, and the end of a span followed by a gap, inside the
block and not on a break. Manual blocks are untouched.

Tests: `boundedReach` (inside base; window smaller than view → centred;
inverted base axis kept; window touching the content edge); planner: pointer
roaming inside a small window → every centre keeps the view inside window +
margin and the pointer inside the hard margin; pointer leaving the window →
next shot unbound; window change at a resettle time with a still pointer → one
eased move, `isCut == false`; no windows → shots equal today's exactly.
`AutoZoomTrack`: with a window, every keyframe's view (at weight 1) stays
inside window + margin while the pointer is inside it, and the pointer is
inside the view; without windows the track equals the no-hint track.

## Task 5 — Scale from a small window (pure)

`AutoZoomSuggester.suggest` gains `windows: [WindowSpan] = []` (master time).

For each click of `activity.clicks` whose window at the click's time contains
the click point: `fit = min(view.w / (win.w·(1+2·boundMargin)), view.h / (win.h·(1+2·boundMargin)))`,
kept only when `fit ≥ minScale` (a window small enough to be worth fitting),
placed at the click's collapsed time. A run's scale is the smallest of its
reveal fits and window fits, clamped and rounded as today. A run with neither
keeps `scale == nil`.

Effect: a run inside one small dialog gets the scale at which the dialog (plus
margin) fills the frame; the bound then centres the frame on it.

Tests: clicks inside a small window → scale = fit (formula); window too big →
nil as today; reveal and window in one run → the smaller; `windows` empty →
output equals today's exactly.

## Task 6 — Model wiring

`StudioModel`:

- `private var zoomWindows: [WindowSpan] = []`, set in `loadOverlayData` from
  `bundle.windowsURL` (missing / unreadable → empty; cleared in the no-events
  early return).
- `withCollapsedTimeline`: snapshot, `WindowHints.collapsed`, restore.
- `zoomTrackConfig`: `c.windows = zoomWindows`.
- `generateAutoZoom`: pass `windows: zoomWindows`.

No UI. No new permission, no entitlement.

## Task 7 — Verify

- `swift test` on Xcode and CLT.
- Build the app and launch it (no crash on an old bundle without the file).
- Code review pass on the diff.
- Needs the user: a new recording of a small window on a large display
  (success criterion 8), and that recording feels unchanged (criterion 10).

## Out of scope here

- 3b (Accessibility: clicked element, caret).
- Window changes as suggester walls (a whole-screen redraw already is one).
- Bounding manual blocks; any UI for windows.

## Scrutiny outcome (2026-11-28)

The plan above was reviewed against the code before implementation. The rules
below replace Tasks 2–5 where they differ.

**Which window (Task 2).** The topmost layer-0 window *under the pointer*, not
the front app's first window: the bound only ever matters for the window the
pointer is in, and a completion list or popover elsewhere must not steal it.
No window under the pointer → "none". A window that does not intersect the
captured rectangle is written as "none" (nothing about other displays is
logged). Sampled at 10 Hz and once 0.12 s after each mouse-down; the window
list call runs on a serial background queue (a tick is skipped while one is in
flight), so the main thread and the 60 Hz pointer sampler never wait on it.
Cancelled on every path that cancels the event tracker, including the
internal-error exit of `stop()`.

**Spans (Task 3).** A span must last 1.0 s (was 0.6). A first line within
0.5 s of the start applies from 0.

**Bound (Task 4).** No per-shot "leave the window, end the shot" rule and no
re-settling. Shots are found from the pointer exactly as today; the bound only
changes where each shot's *centre* is clamped:

- A shot holds from its arrival to the next exit. Its allowed area is the
  window ∪ the pointer path's box over that hold ∪ the reveal it leans toward,
  grown by `boundMargin` (7% of the view per side). The pointer stepping a few
  pixels outside the window therefore widens the area by a few pixels instead
  of releasing the camera, and a menu that opens outside the window is still
  framed. A pointer path that does not touch the window (grown by the margin)
  → unbound.
- A window change during a hold splits it: same aim, new allowed area. A new
  shot (`tExit == tArrive ==` the change, eased, not a cut) is emitted only
  when the centre moves by at least 2% of the view. A change less than `dMin`
  after the hold starts applies from its start.
- An axis with less than 2% of the view of slack is centred (no micro-pans).
- Follow moves out of a bound shot are timed from its centre, not its aim
  (`moveTime`'s `from`), because the two now differ routinely.
- Overflow blocks are never bound (the user chose a free camera).
- No windows → bit-identical output.

**Scale (Task 5).** `fit = (1 − 2·boundMargin) · view / window`, per axis, the
smaller; floored to 0.05 so the window plus margin always fits. It applies
only when the run has clicks and *every* click of the run is inside a window
whose fit is at least `minScale` — one click in a dialog never rescales a long
run. A typing block's hold point is moved inside the same bound (using the
run's scale, else `AutoZoomSuggestConfig.defaultScale`), so typing in a small
dialog does not pan away from the framing the follow blocks around it use.

**After code review.** The first click of a run may be outside the window (it
is the click that opened it) without vetoing the window's scale. "Only this
block" on a block with its own scale frames typing for that scale. Between two
window-decided framings a shift under 2% of the view is not a move, and a
window that drops out for less than `dMin` and comes back is no change.

Accepted as is: a follow block split inside a bound hold can make a small move
at the seam; window changes are stamped up to 0.1 s late.
