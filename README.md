# Capture Studio

A free, open-source macOS screen recorder and simple editor — built as a [Screen Studio](https://screen.studio) alternative. Lives in your menu bar.

## Features

- **Screen recording** — full display capture at 60 fps, selectable display, high-bitrate H.264 masters
- **Area capture** — record just a rectangle of a display: a macOS-screenshot-style drag-select overlay dims every screen at once; the screen you drag on *is* the capture display (derived from the drag, not a separate choice). A live outline marks the captured bounds during preview and recording
- **Cursor-free masters** — the cursor is *not* baked into the video; cursor positions, clicks, and scrolls are captured as a separate 60 Hz event stream. The Studio editor reconstructs a synthetic cursor at render time (toggle on/off) plus optional click-feedback rings
- **Camera** — record any camera as a separate track, shown as a draggable/resizable picture-in-picture overlay; style it with shape (rectangle/circle), corner radius, border color, drop shadow, aspect-ratio preset, feed zoom/pan, and 90° rotation
- **Microphone** — selectable input device, recorded as a separate track; a camera's own mic is captured on the camera's session so it isn't lost to device contention. Studio mic volume boosts up to 300% for quiet voice
- **Android phone as camera/mic (Wi-Fi)** — use an Android phone as the main video source, front camera, or microphone over your local network; H.264/AAC over TLS pinned to the phone's identity, paired once with a 6-digit code
- **System audio** — captures what your Mac is playing (excluding the app itself)
- **Preview-then-record** — warm up all sources (camera spin-up, etc.) and confirm a live camera preview *before* the countdown, so the counter marks a near-instant start
- **Global hotkey** — user-configurable shortcut toggles recording from anywhere (off by default); reuses the last device/region selections without opening the popup
- **Text & captions** — add styled text overlays (font, weight, color, alignment, optional background box and stroke) with their own timeline; blocks may overlap so several can show at once. Each block has a `[begin, end)` span you drag on a timeline lane, position by dragging on the canvas, and edit inline
- **Camera timeline** — show/hide the camera overlay over time as `CameraBlock` segments on a dedicated lane, instead of an all-or-nothing toggle
- **Canvas inspection** — pan and zoom the editor canvas while inspecting; click empty space or press Esc to deselect
- **Studio editor** — opens automatically after recording: preview, trim in/out, per-source volume sliders (system audio vs mic), camera overlay styling, camera/text timelines, cursor/click overlays, and reframe crop (Original/9:16/1:1/4:5/16:9/4:3)
- **Export** — 1080p, 4K, or source resolution MP4; reframed output follows the chosen crop aspect
- **Non-destructive** — recordings are `.capturestudio` bundles; master files are never modified, all edits are metadata (`edit.json`)

## Requirements

- macOS 15 (Sequoia) or later
- Permissions, requested on first use: **Screen Recording** (required), **Camera** and **Microphone** (optional, only if you enable those sources)

## Install

Grab the latest zip from [Releases](../../releases), then:

```sh
unzip CaptureStudio-*.zip
xattr -cr CaptureStudio.app   # required: the app is ad-hoc signed, not notarized
mv CaptureStudio.app /Applications/
```

Without the `xattr` step, macOS Gatekeeper will report the downloaded app as damaged.

Launch it — a camera icon appears in your menu bar. Click it to pick a display, toggle camera/mic/system audio, and start recording.

## Use your Android phone as a camera (Wi-Fi)

1. Download `CaptureStudioPhone.apk` from [Releases](../../releases) and sideload it (Android 11 or later).
2. Open **Capture Studio Phone**, grant camera, microphone, and notifications, and allow unrestricted battery use (Samsung and others put background apps to sleep otherwise).
3. Keep the phone and the Mac on the same Wi-Fi.
4. In Capture Studio's menu-bar popup, pick the phone under **Phone (Wi-Fi)** in the **Main**, **Front camera**, or **Microphone** picker. Use **Find phones…** the first time; macOS asks for Local Network access.
5. On first use the Mac shows a 6-digit code ("Confirm 483 921 on ..."). Check the same code on the phone and tap **Allow**.

The phone streams H.264/AAC over TLS, pinned to the phone's identity. To re-pair, choose **Forget** for the phone in the picker and **Revoke** the Mac under "Paired computers" on the phone.

Tips:

- A phone used as the main video records as `main-camera.mp4`; Studio applies the file's rotation.
- Pick the same phone for video and mic if you want both from it.
- If Wi-Fi drops mid-recording, what was captured is saved and the track is marked truncated.
- "Update required" in the picker means the phone app and Capture Studio use different protocol versions; update the older one.

## Build from source

Requires Xcode command line tools (Swift 6 toolchain).

```sh
git clone https://github.com/wadjakorn/capture-studio.git
cd capture-studio
scripts/build-app.sh release
open dist/CaptureStudio.app
```

The build script signs with a local certificate named `Capture Studio Dev` if one exists in your keychain, otherwise falls back to ad-hoc signing. A stable self-signed certificate is optional but avoids re-granting Screen Recording permission after every rebuild.

Run tests with `swift test`.

## Recording bundle format

Each recording is a directory bundle:

```
My Recording.capturestudio/
├── meta.json        # schema-versioned: display info, per-track sync anchors
├── screen.mp4       # screen master (no cursor rendered)
├── camera.mp4       # if camera enabled
├── mic.m4a          # if mic enabled
├── system.m4a       # if system audio enabled
├── events.jsonl     # cursor positions (60 Hz), clicks, scrolls
└── edit.json        # editor state: trim, volumes, camera overlay + styling + rotation,
                     #   camera visibility timeline (CameraBlocks), text/caption blocks,
                     #   reframe crop, cursor/click-feedback toggles
```

For an area recording the screen master holds only the selected rectangle, and `meta.json` stores **region-relative** display info (origin/point-size shifted to the region) so every Studio coordinate transform stays valid with no editor changes.

All tracks are stamped against the host clock, so alignment is pure arithmetic on stored offsets — no waveform-sync guessing.

## License

[MIT](LICENSE)
