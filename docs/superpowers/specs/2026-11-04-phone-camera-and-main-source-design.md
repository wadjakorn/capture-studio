# Phone camera/mic sources + any camera as main video — design

Date: 2026-11-04. Status: draft for review.

## Intent

Two related recorder capabilities:

1. **Phone as camera and mic.** A Samsung Galaxy (priority) or other Android
   phone appears in the Camera and Microphone pickers and records reliably.
2. **Any camera as the main video.** The main track no longer has to be a
   display. Example: phone camera is the main video, the MacBook camera is the
   front (overlay) camera, phone mic or any mic is the audio.

Why: talking-head and product-demo recordings want a real camera as the primary
image, with the screen either absent or irrelevant. Phone cameras are the best
camera most users own.

## Ground truth (verified 2026-11-04)

How macOS can see an Android phone's camera and mic today:

| Path | Phones | Camera | Mic | How it appears to AVFoundation |
|---|---|---|---|---|
| Native USB webcam mode (UVC) | Galaxy S26 series on One UI 8.5 only; Pixel on Android 14+ | yes, 720p/1080p | **no** (video only) | `AVCaptureDevice.DeviceType.external` |
| Third-party app (Camo, Iriun, DroidCam) over USB or Wi-Fi | any Galaxy | yes | yes, via the app's virtual audio device | camera via Core Media I/O camera extension → `.external`; mic → `.microphone` |
| Samsung Camera Share / Phone Link | any recent Galaxy | yes | yes | Windows only. Not usable on macOS. |

Consequences:

- The current `DeviceDiscovery` already enumerates `.external` cameras and all
  `.microphone` devices, so phone sources are probably *listed* today. The work
  is reliability and UX, not basic enumeration. The plan's first task is to
  verify this against a real phone.
- A phone **mic** on macOS without a third-party app does not exist. The only
  first-party route would be our own Android companion app plus a receiver in
  Capture Studio. That is a separate project (see "Deferred").

Sources: [SamMobile on One UI 8.5 wired webcam](https://www.sammobile.com/news/how-to-use-galaxy-phone-as-webcam-windows-mac/),
[Esper on Android 14 DeviceAsWebcam](https://www.esper.io/blog/android-14-device-as-webcam),
[Apple `DeviceType.external`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/external.md),
[Apple Core Media I/O camera extensions](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o.md).

## Goals

- A phone plugged in (or a virtual-camera app started) *after* the tray popup
  opened shows up without reopening the popup.
- Phone cameras and phone mics are labeled recognizably (device name as the OS
  reports it, grouped under "Phone" when detectable).
- UVC and virtual cameras record without the writer failing on odd formats,
  resolution switches, or missing recommended settings. A disconnect
  mid-recording keeps what was captured and marks the track truncated.
- The user can pick a camera as the **main** source and optionally a second
  camera as the front/overlay camera. The project opens in Studio with the
  camera as the base layer, overlay camera as PiP, mic audio aligned by host
  clock, and all existing editing tools that make sense (trim, cuts, crop,
  camera PiP styling, text, shapes, subtitles, export).
- Old bundles open unchanged. New bundles with a display main open in old
  builds unchanged.

## Non-goals

- Wireless phone camera transport implemented by us (our own Android app or
  RTSP/NDI/WebRTC receiver). Deferred.
- System audio when the main source is a camera. System audio rides the
  ScreenCaptureKit stream, which would show the screen-recording indicator and
  capture a screen nobody asked for. Disabled in camera-main mode for now.
- Area selection or cursor/click/zoom features when the main source is a camera
  (there is no screen).
- More than two cameras, or more than one mic.

## Anti-goals

- Regressing the host-clock sync invariant or the CameraRecorder master-clock
  fix. Every track still stamps `sessionStartHostTime`; offsets are arithmetic.
- Changing the `DisplayInfo` schema. Camera-main writes synthetic values.
- Baking the overlay camera into the main track at record time.

## Constraints

- Command Line Tools only; swift-testing 0.12.0 and KeyboardShortcuts 1.10.0
  pinned. No new dependencies.
- macOS 15+, so `.external` is correct and `.externalUnknown` is not needed.
- Keep `swift build` / `swift test` green at every task boundary.

## Design

### Part A — phone sources

**A1. Hot-plug refresh.** `RecorderMenuView` observes
`AVCaptureDevice.wasConnectedNotification` / `wasDisconnectedNotification`
while open and re-runs discovery. `refreshDevices()` today returns early
without Screen Recording permission (`RecorderMenuView.swift:609`); it must
enumerate cameras and mics regardless and only skip `displays()` when the
permission is missing (see B0). A disconnected selected device becomes
"None" (selection cleared, last-used id kept in `AppSettings` so it comes back
when replugged).

**A2. Labeling.** `DeviceDiscovery` gains a pure classifier
`DeviceKind.classify(name:, manufacturer:, modelID:, deviceType:)` returning
`.builtIn | .phone | .external | .virtual`. Heuristics: Continuity Camera or
manufacturer/name containing Samsung, Galaxy, Android, Iriun, DroidCam, Camo,
EpocCam → `.phone`; other `.external` → `.external`; `.builtInWideAngleCamera`
→ `.builtIn`. Mic classification uses the same name heuristics. Pickers show
groups in order Built-in, Phone, External/Virtual. Pure, unit-tested.

**A3. Robust camera capture.** In `CameraRecorder.warmUp()`:
- Try `sessionPreset = .high`; if `canSetSessionPreset` fails, use
  `.inputPriority` and pick the device's best format ≤ 1080p with the highest
  max frame rate (pure chooser, unit-tested on synthetic dimension/fps tuples).
- If `recommendedVideoSettingsForAssetWriter` returns nil, fall back to an
  explicit H.264 settings dictionary sized from the active format.
- Observe `AVCaptureSessionRuntimeError` and `wasDisconnectedNotification` for
  the camera device: call `markTruncated()` (currently defined but never
  called) and stop appending. `stop()` still finalizes what was written.
- Observe `wasDisconnectedNotification` for the hosted mic the same way.

**A4. Mic on camera session.** Unchanged logic; the existing fallback to a
standalone `MicRecorder` covers virtual audio devices that refuse to join the
camera session. Add a log line naming the device so field reports are usable.

**A5. In-app hint.** A small "Use your phone as a camera" help popover in the
camera picker: Galaxy S26 → USB webcam mode in the USB notification; any
Android → open Capture Studio Phone on the same Wi-Fi (see the companion
design). No third-party apps are recommended (user decision 2026-11-04).

### Part B — main source

**B0. Permissions.** Camera-main must work **without** Screen Recording
permission (a talking-head user never records the screen). Today the whole
recorder is gated on it: `startFromIdle` no-ops without it
(`RecordingSession.swift:623`), `arm()` begins with `DeviceDiscovery.displays()`
which throws without it (`:179`), and the popup shows `permissionView` instead
of the recorder. Rule: the Screen Recording gate applies only when the main
source is a display. Without the permission the popup shows the recorder with
the Main picker listing cameras only plus an inline "Grant Screen Recording to
record a display" row.

**B1. Model.** New enum in `Recorder/`:

```swift
enum MainSource: Equatable {
    case display(CGDirectDisplayID)
    case camera(uniqueID: String)
}
```

`AppSettings.lastMainSource` persists it (two keys: kind + id). Existing
`lastDisplayID` keeps working for the display case so the hotkey path is
unchanged for existing users.

**B2. Recorder UI.** The Display picker becomes a **Main** picker listing
displays and cameras. The existing Camera picker becomes **Front camera** and
hides whichever camera is the main source. When main is a camera: Area toggle,
system-audio toggle, and Select Area are disabled with a tooltip explaining
why. Hotkey: `toggleFromHotkey()` reads `lastMainSource`.

**B3. RecordingSession.** `arm(...)` takes `main: MainSource` instead of
`displayID`. Camera availability is checked against one helper
`availableCameraIDs()` and recorders are built through one factory
`makeCameraSource(id:…)`, so Part C can add Wi-Fi phones without touching
the state machine. The session stores `armedMain: MainSource` and every branch
(`beginRecording`, `startCountdownThenBegin`, `stop`, teardown) switches on it
explicitly. `screenRecorder == nil` is already a load-bearing sentinel meaning
"area deferred, rebuild at record time" (`buildDeferredScreenRecorder`,
`RecordingSession.swift:666`), so nil must not double as "camera-main".
Camera-main path:
- No `ScreenRecorder`, no `EventTracker`, no region, `areaSelection =
  .unavailable`, no Screen Recording permission check.
- `mainCameraRecorder: CameraRecorder` (writes `main-camera.mp4`) is
  **mandatory**: warm-up failure → `.failed`, `beginWriting` failure →
  tear down and `.failed`, mirroring how the screen recorder is treated.
- `cameraRecorder` (overlay, `camera.mp4`) stays best-effort.
- Mic hosts on the **main** camera's session (same device-contention
  reasoning as today); fallback to the overlay session is not attempted;
  fallback to standalone `MicRecorder` is.
- Preview: two `CameraPreviewPanel`s on `NSScreen.main` (there is no chosen
  display; `CameraPreviewPanel`, `CountdownOverlay` and `PreviewHUD` already
  fall back to it for a nil display id). Main panel is larger and sits above
  the HUD at bottom-center; overlay panel keeps today's corner placement. The
  HUD is unchanged except Select Area hidden.
- Hotkey: camera-main always behaves like today's camera flow (first press
  arms + previews, second press records). The main source wins over a
  persisted Area toggle: with `lastMainSource == .camera`, `toggleFromHotkey`
  ignores `captureAreaEnabled` and the saved region.
- `stop()`: anchor is the main track's `sessionStartHostTime`. `displayInfo`
  written to meta is synthetic: `displayID 0`, pixel size = main video's
  written dimensions, point size = pixel size, `scaleFactor 1`, origin 0.
  No `events.jsonl`.

**B4. Bundle format.** Camera-main bundles write `schemaVersion: 2`. Old
builds ignore the version, show the card as ready and fail in Studio with
"Bundle has no screen track" — accepted; the version bump exists so a future
build can gate on it. `TrackInfo` gains `var role: TrackRole? = nil` with
`enum TrackRole: String, Codable { case main, overlay }`. `ProjectMeta` gains
`var mainSource: String? = nil` ("display" | "camera") for Dashboard badges
only. Resolution rule, implemented once in `ProjectMeta`:

- `mainTrack` = first track with `role == .main`, else first `.screen` track.
- `overlayCameraTrack` = first `.camera` track with `role != .main`.

Old bundles (no roles) resolve exactly as today. `ProjectBundle` gains
`mainCameraURL` (`main-camera.mp4`) and `url(for: TrackInfo)`.

**B5. Studio.** `makeComposition` uses `meta.mainTrack` and `url(for:)`
instead of `type == .screen` / `bundle.screenURL`; render size comes from the
main track's natural size **after applying its `preferredTransform`**
(today ignored; Part C writes rotated phone video), so a portrait phone gives
a portrait canvas and crop handles it.
Overlay camera uses `overlayCameraTrack`. Cursor rendering
(`StudioModel.swift:2527`) and the Zoom inspector controls
(`ZoomInspector.swift:79`) are gated on `hasCursorData`, but the zoom timeline
lane is always built (`StudioWindow.swift:292`) and auto-zoom
(`StudioModel.swift:1434-1449`) does not check for events. Both must be gated
on `hasCursorData` too. Nothing else reads `meta.display` for geometry
(`loadOverlayData` is a no-op without events).

**B6. Dashboard.** `ThumbnailStore` and `duration` use the main track's file
(they are the only `screen.mp4` readers; `ProjectLibrary` validity is
`meta.json` presence + decodability and needs no change). `ProjectSummary.
hasCamera` becomes "has overlay camera" and a new `isCameraMain` drives a
separate badge.

### Part C (separate design)

Native phone camera + mic over Wi-Fi with our own Android app and no adb:
`2026-11-04-phone-companion-design.md`. Decided 2026-11-04: no third-party
apps. Part A's third-party rows (Iriun/Camo/DroidCam) still classify as
`.phone` if present, but the app never suggests installing them.

## Test hardware

Preferred: a Galaxy S26 in USB webcam mode, or any Galaxy with Iriun/Camo.
If none is on hand, proxies: Continuity Camera (iPhone) for a phone-class
`.external`/`.continuityCamera` device, OBS Virtual Camera for a virtual
camera, and unplugging a USB webcam for the disconnect path. A3's format
fallbacks are then best-effort until a real phone is tested.

## Calls made by the author (not confirmed by the user)

- Camera-main does not require Screen Recording permission.
- Camera-main hotkey is two-press (arm/preview, then record); main source
  wins over the Area toggle.
- Camera-main bundles use `schemaVersion 2`; old builds are not protected.
- Preview panels and countdown go on `NSScreen.main` in camera-main mode.

- Camera-main disables system audio rather than keeping a hidden screen stream.
- Main camera file is `main-camera.mp4` with a `role` field, not a reuse of
  `screen.mp4`.
- Mic hosts on the main camera session, not the overlay session.
- Two preview panels rather than a composited single preview.
- Phone detection is name/manufacturer heuristics, no model database.
