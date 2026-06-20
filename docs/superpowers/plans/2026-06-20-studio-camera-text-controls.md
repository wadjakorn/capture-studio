# Studio Camera + Text Controls Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the dead global camera on/off toggle and split the Studio camera controls into one style dropdown + one motion action group; make the text tools consistent and stop the text style popover clipping.

**Architecture:** Pure SwiftUI editor-UI work in two files. `StudioModel` gains visibility-gating fixes plus two small helpers (`blockAtPlayhead`, `addHideBlock`). `StudioWindow` restructures the camera control group, moves the zoom slider into the style popover, and fixes the text tools. One pure unit test is added at the `CameraTimeline` layer for hide-block insertion.

**Tech Stack:** Swift 6 toolchain (Command Line Tools only), SwiftUI, swift-testing.

## Global Constraints

- Toolchain: Command Line Tools only — no Xcode.app. Do not bump swift-testing (`0.12.0`) or KeyboardShortcuts (`1.10.0`).
- Build with `swift build`; test with `swift test`. Keep all existing tests green (currently 45).
- **Never commit or push without explicit user confirmation** (project rule, CLAUDE.md). Each "Commit" step below means: stage the change and ask the user to confirm before running `git commit`.
- Commit messages in normal English, end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Architecture invariants must not regress (cursor not baked in, host-clock sync, region-relative DisplayInfo, own-app windows excluded, preview/record split). None of these tasks touch capture.

---

### Task 1: Camera global toggle fix

The toggle currently flips `cameraVisible`, but the render path forces the camera on whenever a block timeline exists (`cameraVisible || cameraHasTimeline`), and the lane row is gated on `cameraHasTimeline` alone. Gate all three on `cameraVisible`.

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (around lines 81, 108-114, 998)
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift:60`

**Interfaces:**
- Produces: `var showsCameraTimeline: Bool` on `StudioModel` (true only when the camera is visible *and* has a block timeline).

- [ ] **Step 1: Add `showsCameraTimeline` and gate the PiP overlay on `cameraVisible`**

In `StudioModel.swift`, next to `cameraHasTimeline` (line ~81) add:

```swift
/// The camera lane is shown only when the camera is visible *and* has a
/// block timeline. Toggling the camera off hides the lane (blocks retained).
var showsCameraTimeline: Bool { cameraVisible && cameraHasTimeline }
```

Then change `showsCameraOverlay` (line ~108) to bail when the camera is hidden:

```swift
var showsCameraOverlay: Bool {
    guard hasCameraTrack else { return false }
    guard cameraVisible else { return false }
    guard cameraHasTimeline else { return cameraVisible }
    if selectedBlock != nil { return true }
    if let first = cameraBlocks.first, currentTime < first.begin { return true }
    return false
}
```

- [ ] **Step 2: Gate the render `cameraShown` on `cameraVisible` only**

In `buildVideoComposition` (line ~998) change:

```swift
let cameraShown = cameraTrackID != nil && cameraVisible
```

(removing `|| cameraHasTimeline`).

- [ ] **Step 3: Gate the camera lane row on `showsCameraTimeline`**

In `StudioWindow.swift` `controlBar` (line ~60) change:

```swift
if model.showsCameraTimeline {
    laneRow("video.fill") { CameraTimelineLane(model: model) }
}
```

- [ ] **Step 4: Build and verify**

Run: `swift build`
Expected: builds with no errors.

Run: `swift test`
Expected: all existing tests pass (no behavior change to pure logic).

- [ ] **Step 5: Manual check**

Build the app (`scripts/build-app.sh debug`), relaunch (`pkill -x CaptureStudio; open dist/CaptureStudio.app`), open a recording with camera blocks. Toggle the `video.circle` button: camera disappears from canvas AND the camera lane hides; blocks are retained; re-toggle restores both.

- [ ] **Step 6: Commit** (stage, then ask the user to confirm before committing)

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "Fix global camera toggle to hide camera in canvas and timeline

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Hide-block insertion (model + pure test)

Add a one-click "insert a temporary hide block at the playhead" action, plus the `blockAtPlayhead` query that gates its enabled state. The core logic — a block with `visible == false` from a zero-opacity placement — is a pure `CameraTimeline.add` behavior, so test it there.

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (add helpers near `addBlock`, line ~565)
- Test: `Tests/CaptureStudioTests/CameraTimelineTests.swift`

**Interfaces:**
- Consumes: `CameraTimeline.add(_:atTime:width:duration:placement:)` (existing) which sets `visible: placement.opacity > 0.5`; `sampledCameraState(at:)` (existing, used by `addBlock`); `setBlocks(_:select:)` (existing private).
- Produces on `StudioModel`: `var blockAtPlayhead: CameraBlock?`, `func addHideBlock()`.

- [ ] **Step 1: Write the failing test**

Add to `CameraTimelineTests.swift` (in the `// MARK: add` section):

```swift
@Test func addWithZeroOpacityPlacementMakesHiddenBlock() {
    let hidden = CameraSample(centerX: 0.5, centerY: 0.5, scale: 0.3, opacity: 0)
    let r = CameraTimeline.add([], atTime: 5, width: 2, duration: 30, placement: hidden)
    #expect(r.blocks.count == 1)
    #expect(r.blocks[0].visible == false)
    #expect(r.blocks[0].begin == 5)
    #expect(r.blocks[0].end == 7)
}
```

- [ ] **Step 2: Run test to verify it passes against existing code**

Run: `swift test --filter addWithZeroOpacityPlacementMakesHiddenBlock`
Expected: PASS — `CameraTimeline.add` already maps `opacity <= 0.5` to `visible == false`. This test pins the contract `addHideBlock` relies on. (If it somehow fails, stop — the assumption behind `addHideBlock` is wrong.)

- [ ] **Step 3: Add `blockAtPlayhead` and `addHideBlock` to `StudioModel`**

Immediately after `addBlock()` (line ~572) in `StudioModel.swift`:

```swift
/// The block whose span strictly contains the playhead, if any. Used to
/// gate hide-block insertion (no overlapping blocks).
var blockAtPlayhead: CameraBlock? {
    cameraBlocks.first { $0.begin <= currentTime && currentTime < $0.end }
}

/// Insert a "temporary hide" block at the playhead — a zero-opacity
/// placement so `CameraTimeline.add` produces a `visible == false` block,
/// fading the camera out over the block. Caller gates on `blockAtPlayhead`.
func addHideBlock() {
    let t = min(max(currentTime, 0), duration)
    var placement = sampledCameraState(at: t)
    placement.opacity = 0
    let added = CameraTimeline.add(cameraBlocks, atTime: t,
                                   width: Self.defaultBlockWidth,
                                   duration: duration, placement: placement)
    setBlocks(added.blocks, select: added.id)
}
```

- [ ] **Step 4: Build and run the full suite**

Run: `swift build && swift test`
Expected: builds clean; all tests pass (now 46).

- [ ] **Step 5: Commit** (stage, then ask the user to confirm before committing)

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift Tests/CaptureStudioTests/CameraTimelineTests.swift
git commit -m "Add hide-block insertion and playhead-overlap query to StudioModel

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Camera controls UI restructure

Split the camera tool group into: on/off toggle, one style dropdown (zoom + all frame style), one motion action group (Add move / Delete / Hide). Remove the "Camera motion" section from the style popover and the inline zoom slider; both move into their new homes. Per the design, when the camera is off the dropdown and action group stay visible but disabled.

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` — `cameraControls` (lines ~194-223) and `cameraStylePopover` (lines ~289-387)

**Interfaces:**
- Consumes from Tasks 1-2: `model.cameraVisible`, `model.toggleCamera()`, `model.addBlock()`, `model.removeBlock(_:)`, `model.selectedBlockID`, `model.addHideBlock()`, `model.blockAtPlayhead`, `model.cameraZoom`, `model.setCameraZoom(_:)`, `model.commitCameraEdit()`.

- [ ] **Step 1: Replace `cameraControls`**

Replace the whole `cameraControls` computed (lines ~194-223) with:

```swift
@ViewBuilder private var cameraControls: some View {
    Toggle(isOn: Binding(get: { model.cameraVisible },
                         set: { _ in model.toggleCamera() })) {
        Image(systemName: "video.circle")
    }
    .toggleStyle(.button)
    .help("Show/hide camera overlay")

    // Style dropdown — all global camera config (zoom + frame style).
    Button { showCameraStyle.toggle() } label: {
        Image(systemName: "slider.horizontal.3")
    }
    .disabled(!model.cameraVisible)
    .help("Camera style — zoom, frame & shape")
    .popover(isPresented: $showCameraStyle, arrowEdge: .bottom) {
        cameraStylePopover
    }

    // Motion action group — add / delete / hide camera blocks.
    Button { model.addBlock() } label: {
        Label("Add move", systemImage: "plus.rectangle")
    }
    .disabled(!model.cameraVisible)
    .help("Add a camera move block at the playhead")

    Button {
        if let id = model.selectedBlockID { model.removeBlock(id) }
    } label: {
        Image(systemName: "minus.rectangle")
    }
    .disabled(!model.cameraVisible || model.selectedBlockID == nil)
    .help("Delete the selected move block")

    Button { model.addHideBlock() } label: {
        Image(systemName: "eye.slash")
    }
    .disabled(!model.cameraVisible || model.blockAtPlayhead != nil)
    .help("Insert a temporary hide-camera block at the playhead")
}
```

- [ ] **Step 2: Add the zoom slider to the top of `cameraStylePopover` and remove the camera-motion section**

In `cameraStylePopover` (line ~289), insert this as the first child of the `VStack` (before the `Picker("Shape", …)`):

```swift
VStack(alignment: .leading, spacing: 2) {
    Text("Zoom").font(.caption).foregroundStyle(.secondary)
    Slider(value: Binding(get: { model.cameraZoom },
                          set: { model.setCameraZoom($0) }),
           in: 1.0...4.0) { editing in
        if !editing { model.commitCameraEdit() }
    }
}
```

Then delete the entire trailing camera-motion block (from `Divider()` through the closing of its `HStack`, lines ~358-383) — i.e. remove:

```swift
Divider()

Text("Camera motion").font(.caption).foregroundStyle(.secondary)
HStack(spacing: 8) {
    Button { model.addBlock() } label: {
        Label("Add move", systemImage: "plus.rectangle")
    }
    .help("Add a camera move block at the playhead")

    if model.cameraHasTimeline {
        Button {
            if let id = model.selectedBlockID { model.removeBlock(id) }
        } label: {
            Image(systemName: "minus.rectangle")
        }
        .disabled(model.selectedBlockID == nil)
        .help("Delete the selected move block")

        if let block = model.selectedBlock {
            Button { model.toggleBlockVisible(block.id) } label: {
                Image(systemName: block.visible ? "eye" : "eye.slash")
            }
            .help("Show or hide the camera in this block")
        }
    }
}
```

The popover now ends after the shadow controls. Leave `model.toggleBlockVisible` defined on the model (now unused by the UI) — harmless.

- [ ] **Step 3: Build and verify**

Run: `swift build`
Expected: builds clean. If the compiler warns that `selectedBlock`/`toggleBlockVisible` are unused, that is acceptable (model API kept intentionally).

- [ ] **Step 4: Manual check**

Build + relaunch the app. With camera ON: the style dropdown shows zoom + shape/rotate/aspect/corner/border/shadow (no "Camera motion"); the toolbar shows Add move (always enabled), Delete (enabled only when a block is selected), Hide (disabled when the playhead is inside a block, else enabled — inserts a fade-out block). With camera OFF: dropdown and all three action buttons are visible but disabled; only the toggle is live.

- [ ] **Step 5: Commit** (stage, then ask the user to confirm before committing)

```bash
git add Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "Split camera controls into style dropdown and motion action group

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Text controls — add affordance, always-show dropdown, popover overflow

Give the add-text button a `+` affordance, always show the text style dropdown (disabled with no selection, matching the camera dropdown), and fix the text style popover clipping its left edge.

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` — `textControls` (lines ~225-240), `textStylePopover` frame (line ~550), `textColorRow` (lines ~565-587)

**Interfaces:**
- Consumes: `model.addTextBlock()`, `model.selectedTextBlock`, `showTextStyle`, existing `FlowLayout`.

- [ ] **Step 1: Replace `textControls`**

Replace `textControls` (lines ~225-240) with:

```swift
@ViewBuilder private var textControls: some View {
    Button { model.addTextBlock() } label: {
        Image(systemName: "text.badge.plus")
    }
    .help("Add a text/caption block at the playhead")

    Button { showTextStyle.toggle() } label: {
        Image(systemName: "slider.horizontal.3")
    }
    .disabled(model.selectedTextBlock == nil)
    .help("Edit text style, order, and delete")
    .popover(isPresented: $showTextStyle, arrowEdge: .bottom) {
        textStylePopover
    }
}
```

- [ ] **Step 2: Widen the text style popover**

In `textStylePopover` change the frame (line ~550) from `.frame(width: 248)` to:

```swift
.frame(width: 280)
```

- [ ] **Step 3: Wrap the swatch row so it never overflows**

In `textColorRow` (line ~565), change the swatch container from `HStack(spacing: 6)` to a wrapping `FlowLayout` so the eight swatches + ColorPicker reflow instead of clipping:

```swift
private func textColorRow(_ title: String, hex: String,
                          set: @escaping (String) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        FlowLayout(hSpacing: 6, vSpacing: 6) {
            ForEach(Self.borderPresets, id: \.self) { h in
                let selected = h.caseInsensitiveCompare(hex) == .orderedSame
                Circle()
                    .fill(Color(hexString: h))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                    .overlay(Circle().strokeBorder(Color.accentColor,
                                                   lineWidth: selected ? 2.5 : 0).padding(-2))
                    .onTapGesture { set(h) }
            }
            ColorPicker("", selection: Binding(
                get: { Color(hexString: hex) },
                set: { set($0.hexString()) }
            ), supportsOpacity: false)
            .labelsHidden()
        }
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `swift build && swift test`
Expected: builds clean; all tests still pass (46).

- [ ] **Step 5: Manual check**

Build + relaunch. The add-text button shows a `+` badge. The text style dropdown button is always present, disabled until a text block is selected. Open the popover with a block selected: every label ("Size", "Color", "Outline", etc.) renders fully with no left-edge clipping, and swatches wrap if needed.

- [ ] **Step 6: Commit** (stage, then ask the user to confirm before committing)

```bash
git add Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "Add + affordance and always-show text style dropdown; fix popover clipping

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review notes

- **Spec coverage:** Toggle fix → Task 1. Hide-insert (Q1) + overlap gate → Task 2 + Task 3. Zoom into dropdown (Q2) → Task 3 Step 2. Show-but-disabled when off (Q3) → Task 3 disabled modifiers. Style/motion split → Task 3. Per-block eye toggle removed → Task 3 Step 2. Text `+` / always-show dropdown / overflow → Task 4. All design sections mapped.
- **Type consistency:** `addHideBlock`, `blockAtPlayhead`, `showsCameraTimeline` defined in Tasks 1-2 and consumed by Task 3 with matching signatures.
- **No placeholders:** every code step shows the full code.
