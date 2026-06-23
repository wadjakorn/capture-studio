# Auto Zoom/Pan — Follow Sensitivity

Date: 2026-06-23
Status: Approved (pending implementation plan)
Builds on: [2026-06-23-auto-zoom-pan-design.md](2026-06-23-auto-zoom-pan-design.md)

## Goal

Let the user control how aggressively the auto zoom/pan follows the cursor. The
current behavior pans on even tiny mouse moves (it feels jumpy). Add a single
"Follow sensitivity" control: low = calm (ignores small/slow moves, lazier pan),
high = snappy (follows everything).

## Decisions (locked)

- **One sensitivity slider**, not separate deadzone/smoothing knobs.
- **Global default + per-block override**, mirroring how `ZoomBlock.scale` works.
- Replace the raw `AutoZoomConfig.idleSpeed` / `smoothing` fields with a single
  `defaultSensitivity` (single source of truth); the two low-level knobs are
  derived from sensitivity by a pure mapping.

## Model

Sensitivity `s ∈ [0, 1]` (clamped). Pure mapping (in `AutoZoomTrack`):

```
idleSpeed(s) = 200 - 190·s     // px/s deadzone: s=0 → 200 (ignore small moves), s=1 → 10
smoothing(s) = 0.30 - 0.25·s   // seconds of pan lag: s=0 → 0.30 (laggy), s=1 → 0.05 (snappy)
```

Default `s = 0.5` → `idleSpeed = 105`, `smoothing = 0.175` — calmer than the
shipped values (40 / 0.12, which sit around s≈0.85). So the default feel is
gentler out of the box, and tunable in both directions.

## Changes

1. **`ZoomBlock`** (`EditState.swift`): add `var sensitivity: Double?` (nil =
   use global default), mirroring `scale: Double?`. Add to the memberwise init.
   Optional property → synthesized `Codable` decodes a missing key as nil, so
   persistence stays backward compatible.

2. **`AutoZoom.swift`**:
   - `AutoZoomConfig`: remove `idleSpeed` and `smoothing`; add
     `defaultSensitivity: Double = 0.5`.
   - Add pure `static func tuning(_ s: Double) -> (idleSpeed: Double, smoothing:
     Double)` applying the clamped mapping above.
   - In `build`, resolve per block: `let s = block.sensitivity ??
     config.defaultSensitivity`, then `let (idleSpeed, smoothing) = tuning(s)`.
     Move the `alpha = 1 - exp(-step/smoothing)` computation inside the per-block
     loop (smoothing is now per-block). Use the per-block `idleSpeed` in the idle
     gate.

3. **`StudioModel.swift`**:
   - `autoZoomConfig`: also read `UserDefaults` key `autoZoomDefaultSensitivity`;
     when in `(0, 1]` (i.e. set), override `config.defaultSensitivity` — same
     guard style as `autoZoomDefaultScale`. (A stored `0.0`, the UserDefaults
     default for an unset Double, must NOT override.)
   - Add `selectedZoomSensitivity: Double` getter (block's override, else
     `autoZoomConfig.defaultSensitivity`), `setZoomSensitivity(_:)` (clamp
     `[0, 1]`, live `applyVideoComposition()`), `resetZoomSensitivity()` (sets
     nil, `applyVideoComposition()` + `saveEdit()`) — mirroring the scale ops.

4. **`StudioWindow.swift`**: add a "Follow" slider to `zoomControls` next to the
   scale slider, shown when a zoom block is selected, bound to
   `selectedZoomSensitivity` / `setZoomSensitivity`, committing on edit-end via
   `commitZoomEdit()`. Range `0...1`, shown as a percentage.

## Untouched

- `ZoomTimeline` (block creation still defaults both `scale` and `sensitivity`
  to nil).
- The compositor (`magnify` / track sampling) — sensitivity only changes how the
  track is built, not how it is rendered.
- The existing `scale` per-block-override path.

## Testing

Unit tests (swift-testing):

- `AutoZoomTrack.tuning`: endpoints (`s=0` → (200, 0.30); `s=1` → (10, 0.05)),
  monotonic decreasing in both outputs, clamps out-of-range `s`.
- `build`: a low-sensitivity block ignores a small/slow cursor move (focus stays
  ~frozen) where a high-sensitivity block follows it; per-block `sensitivity`
  overrides `config.defaultSensitivity`; `nil` uses the default.
- Update the two existing `AutoZoomTrackTests` that set `cfg.smoothing` directly
  to set `cfg.defaultSensitivity` instead (anticipation test → high sensitivity
  for low smoothing).
- `EditState`: round-trip `ZoomBlock.sensitivity` (value and nil); old bundle
  without the key decodes to nil.

UI / model wiring is verified by building and running (project convention).

## Open items

- No settings-UI for the global `autoZoomDefaultSensitivity` yet (same deferred
  status as `autoZoomDefaultScale`); the per-block slider is the exposed control.
