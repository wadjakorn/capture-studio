# Capture Studio

A free, open-source macOS screen recorder and simple editor — built as a [Screen Studio](https://screen.studio) alternative. Lives in your menu bar.

## Features

- **Screen recording** — full display capture at 60 fps, selectable display, high-bitrate H.264 masters
- **Area capture** — record just a rectangle of a display: a macOS-screenshot-style drag-select overlay dims every screen at once; the screen you drag on *is* the capture display (derived from the drag, not a separate choice). A live outline marks the captured bounds during preview and recording
- **Cursor-free masters** — the cursor is *not* baked into the video; cursor positions, clicks, and scrolls are captured as a separate 60 Hz event stream. The Studio editor reconstructs a synthetic cursor at render time (toggle on/off) plus optional click-feedback rings
- **Camera** — record any camera as a separate track, shown as a draggable/resizable picture-in-picture overlay; style it with shape (rectangle/circle), corner radius, border color, drop shadow, aspect-ratio preset, feed zoom/pan, and 90° rotation
- **Microphone** — selectable input device, recorded as a separate track; a camera's own mic is captured on the camera's session so it isn't lost to device contention. Studio mic volume boosts up to 300% for quiet voice
- **System audio** — captures what your Mac is playing (excluding the app itself)
- **Preview-then-record** — warm up all sources (camera spin-up, etc.) and confirm a live camera preview *before* the countdown, so the counter marks a near-instant start
- **Global hotkey** — user-configurable shortcut toggles recording from anywhere (off by default); reuses the last device/region selections without opening the popup
- **Studio editor** — opens automatically after recording: preview, trim in/out, per-source volume sliders (system audio vs mic), camera overlay styling, cursor/click overlays, and reframe crop (Original/9:16/1:1/4:5/16:9/4:3)
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
                     #   reframe crop, cursor/click-feedback toggles
```

For an area recording the screen master holds only the selected rectangle, and `meta.json` stores **region-relative** display info (origin/point-size shifted to the region) so every Studio coordinate transform stays valid with no editor changes.

All tracks are stamped against the host clock, so alignment is pure arithmetic on stored offsets — no waveform-sync guessing.

## License

[MIT](LICENSE)
