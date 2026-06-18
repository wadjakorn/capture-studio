# Capture Studio — project guide

macOS menu-bar-only screen recorder + lightweight editor. Open-source Screen Studio
alternative. SwiftUI, Swift 6 toolchain, single SPM package.

## Build / test / run

- **Toolchain: Command Line Tools only — no Xcode.app.** This pins two deps:
  swift-testing `0.12.0` (exact) and KeyboardShortcuts `1.10.0` (exact). Later
  versions need the `#Preview` macro plugin / Testing interop libs CLT lacks. Do
  not bump these.
- `swift build` / `swift test` (currently 45 tests — keep them green).
- `scripts/build-app.sh [debug|release]` → packages `dist/CaptureStudio.app`.
  Signs with the local `Capture Studio Dev` cert if present (keeps TCC grants
  across rebuilds), else ad-hoc.
- After building, relaunch: `pkill -x CaptureStudio; open dist/CaptureStudio.app`.
- Bundle id: `dev.wadjakorn.capture-studio` (stable; TCC + KeyboardShortcuts
  persistence key off it). Target: macOS 15+. `LSUIElement` (no Dock icon).

## Layout

- `Sources/CaptureStudio/App/` — menu-bar UI, settings, overlays, app lifecycle,
  hotkey, area selector.
- `Sources/CaptureStudio/Recorder/` — capture: screen/camera/mic recorders,
  device discovery, event tracking, `RecordingSession` orchestrator.
- `Sources/CaptureStudio/Studio/` — editor: `StudioModel` (state), `StudioWindow`
  (UI), `CameraCompositor` (per-frame Core Image render — cursor/click/camera),
  `Exporter`, crop math.
- `Sources/CaptureStudio/ProjectBundle/` — on-disk `.capturestudio` format:
  `Meta`, `EditState`, `Events`, `ProjectBundle`.
- `Tests/CaptureStudioTests/` — swift-testing; pure helpers (crop math, event
  mapping, codecs). Capture/UI glue is not unit-tested.

## Architecture invariants (do not regress)

- **Cursor not baked in:** `ScreenRecorder.showsCursor = false`. Cursor/clicks
  live in `events.jsonl` (60 Hz); Studio reconstructs them via `CameraCompositor`.
- **Host-clock sync:** every track stamps `sessionStartHostTime`; alignment is
  arithmetic on offsets, no waveform guessing. CameraRecorder master-clock fix
  (audio-gate video `startSession`, monotonic PTS) must stay intact.
- **Region-relative DisplayInfo:** area capture writes shifted origin/point-size
  into `meta.json` so all Studio coordinate transforms work unchanged.
  `DisplayInfo` schema never changes — only the values.
- **Own-app windows excluded from capture:** camera preview + region outline
  panels are app-owned, so they show on screen but never appear in `screen.mp4`.
- **Preview/Record split:** `RecordingSession.arm()` warms sources (no writers);
  `beginRecording()` flips writers on. States: idle/arming/armed/preparing/
  recording/finishing/failed.
- **Area capture display = the drag, not the picker.** Display picker governs
  Full-Display mode only. `captureRegionDisplayID` is saved with the region and
  used at record time (GUI + hotkey).

## Git / commits

- Remote `git@github.com:wadjakorn/capture-studio.git`. **Fast-forward push only,
  never force-push.**
- **Never commit or push without explicit user confirmation.**
- Commit messages in normal English, end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## Working style

- User runs **CAVEMAN MODE** (terse). Prose/responses terse; code, commit
  messages, and security notes in normal English.
