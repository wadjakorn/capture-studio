# Area selection merged into preview flow

**Date:** 2026-06-19
**Scope:** Area capture mode only. Full-display mode and the global hotkey are unchanged.

## Problem

Area capture today takes five steps:

1. Open tray menu, pick the **Area** tab.
2. Click **Select Area…** → modal overlay (dim + aspect bar), drag a rect, confirm with **Use Area** / Return.
3. Overlay closes.
4. Click **Preview** → `arm()` warms sources, re-shows the region as a static outline + camera preview + dim.
5. Click **Record**.

The user sees the region twice and confirms it twice. Goal: collapse select + preview into one live state so the region is editable *while* the preview is up, and recording starts from the tray (or Return), with no confirm button in the overlay bar.

## Target flow (area mode, GUI)

1. Tray menu → **Area** tab → single primary button **"Preview / Select Area"**.
2. Click → `arm()` warms camera/mic and presents the **live selection overlay** (dim + punch-out rect + 8 handles + aspect bar) together with the camera preview (when a camera is selected). The tray armed view shows **Start Record** + **Cancel**.
3. The user drags / moves / resizes / picks an aspect ratio freely. The capture display follows the drag (the rect's screen *is* the capture display). The camera preview stays in its initial position. Live W×H is shown.
4. **Esc** or right-click → cancel → idle. **Start Record** (tray) or **Return / keypad Enter** → countdown → record. There is no confirm button in the overlay bar.

Constraints carried from the existing architecture (do not regress):

- Cursor not baked in; region-relative `DisplayInfo`; host-clock sync; own-app windows excluded from capture; preview/record split.
- The **capture display = the drag, not the picker** (area mode). The display picker still governs full-display mode only.

## Approaches considered

1. **Chain modal → preview** — run today's `AreaSelector` modal, then auto-`arm()` on confirm. Rejected: the area can't be edited *during* preview, and the **Use Area** confirm step survives, so it doesn't meet the requirement.
2. **Live overlay, rebuild `ScreenRecorder` on every drag** — rejected: wasteful and pointless, since the SCStream isn't started until `beginRecording()` anyway.
3. **Live overlay, defer the screen-recorder build to record time** — chosen. The region only needs to be final at Start Record, so the overlay edits a live region and the recorder/`displayInfo` are constructed from the final selection.

## Design

### A. Overlay refactor — `App/AreaSelector.swift`

Repurpose the modal `AreaSelector.Coordinator` into a session-owned, long-lived `AreaSelectionOverlay`:

- `present(initialRegion:initialDisplayID:)` and `dismiss()` replace `selectRegion()`. Remove the `withCheckedContinuation` / `selectRegion()` modal entry point.
- Callbacks:
  - `onChange(region: CGRect, displayID: CGDirectDisplayID, valid: Bool)` — fired live on every drag/resize/aspect/screen change.
  - `onCancel()` — Esc, right-click, `cancelOperation`.
  - `onStart()` — Return / keypad Enter (only meaningful when `valid`; the overlay forwards it and the session ignores it if not armed-valid).
- The key monitor maps: Esc (53) → `onCancel`; Return (36) / keypad Enter (76) → `onStart`. No confirm-via-Return-builds-region behavior remains.
- The overlay's own dim + punch-out rect is the preview dim during area preview — it replaces `CaptureDimOverlay` and the static `RegionOutlineOverlay` *for the preview phase only*.
- Cross-screen behavior is unchanged from today: dragging onto another screen drops the old selection and the new screen becomes active. The capture display is derived from the active screen.

### B. Control bar — `App/AreaControlBar.swift`

- Remove the **Use Area** and **Cancel** buttons from `AreaControlBar` and the corresponding `onConfirm` / `onCancel` from `AreaControlModel`.
- Keep the aspect-ratio chips and the live W×H readout.
- Add a hint line: **"Enter to record · Esc to cancel"** (locked copy).
- `canConfirm` is repurposed/renamed to `valid` (drives nothing visible in the bar; reported to the session via `onChange`).

### C. Tray menu — `App/RecorderMenuView.swift`

- In `captureModeRow`, remove the **Select Area…** button row. Keep only a small saved-region readout (`display · W×H`, or "Not set").
- Primary idle button label: **"Preview / Select Area"** in area mode; **"Preview"** stays for full display.
- Area mode's primary button calls `session.toggle(..., previewFirst: true, interactiveArea: true)`.
- Armed view: gate the **Record** button with `.disabled(!session.canBeginArmed)`. Show the live region size in the armed view. For the interactive-area case the armed-view header copy reads **"Adjust area, then record"** (instead of "Sources ready").

### D. Session — `Recorder/RecordingSession.swift`

- Add an `interactiveArea: Bool` parameter threaded through `toggle` → `startFromIdle` → `arm`.
- `arm(..., interactiveArea:)`:
  - Non-interactive paths (full display, hotkey area, camera-only) behave exactly as today: build `ScreenRecorder` + `displayInfo` at arm, show `CaptureDimOverlay` / `RegionOutlineOverlay` as applicable.
  - Interactive-area branch: create the bundle, warm camera/mic, present `AreaSelectionOverlay` (seeded with the saved region/display if any), and leave `screenRecorder` and `displayInfo` **nil**. `armedRegion` / `armedDisplayID` are updated live from the overlay's `onChange`; `canBeginArmed` mirrors `valid`.
- Add `@Published private(set) var canBeginArmed: Bool` — `true` for every non-interactive path; equals the live `valid` flag for interactive area. Drives the tray Record button.
- `startCountdownThenBegin()` (and/or `onStart` from the overlay): if `screenRecorder == nil` (interactive area), build it now from the final `armedRegion` / `armedDisplayID`:
  - Re-resolve the display via `DeviceDiscovery.displays()`; on failure → `.failed`, abort.
  - Construct `ScreenRecorder` with the clamped final region, set `displayInfo = item.displayInfo(region:)`.
  - Persist the final region + display to `AppSettings.captureRegion` / `captureRegionDisplayID`.
  - Dismiss the live overlay; show a static `RegionOutlineOverlay` for the chosen region (persists through recording).
  - Then run the countdown and `beginRecording()` (existing guards on `screenRecorder` / `displayInfo` hold).
- Esc → `cancelCountdownOrArming()` → existing teardown (closes overlay, camera preview, deletes bundle) → idle.
- `tearDownArmed`, `stop`, `tearDownForQuit` close the new overlay alongside `previewPanel` / `regionOutline` / `dimOverlay`.

### E. Hotkey (unchanged)

`toggleFromHotkey` keeps `interactiveArea: false`: it uses the saved region on its saved display and arms non-interactively (camera → static preview awaiting a second press; screen-only → record directly). A hotkey cannot pop the interactive selector.

## Risks to verify on-device

- **Panel z-order / mouse routing:** the camera preview must sit above the selection dim yet not steal drag events; the aspect-bar panel must sit above both. Verify `NSPanel.level` values and `ignoresMouseEvents`.
- **Own-app capture exclusion** still holds for the live overlay (app-owned panels → absent from `screen.mp4`). Static outline during recording is unchanged.
- **Display removed between preview and record:** build fails → `.failed` with a clear message, no partial bundle left.
- **First run / nil saved region:** overlay opens empty and draggable; `canBeginArmed` is false until a ≥ `minSize` drag exists; Record / Return are inert until then.

## Testing

UI/overlay glue is not unit-tested per project convention; keep the existing 45 tests green. If a pure helper falls out (e.g. a region-validity check), extract it and add a swift-testing case. Manual verification via `scripts/build-app.sh debug` + relaunch:

- nil saved region (first run), single display.
- multi-display: drag the selection across screens; confirm capture display follows and camera preview stays put.
- camera on and off.
- Esc cancels to idle (no bundle left behind); Return and tray **Start Record** both record.
- aspect-ratio templates still constrain the live selection.

## Out of scope

- Full-display preview behavior, the display picker, and the global hotkey flow.
- Any change to the on-disk `.capturestudio` format, `DisplayInfo` schema, or host-clock sync.
- Repositioning the camera preview when the selection changes screens (camera preview stays put by decision).
