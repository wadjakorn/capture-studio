# Canvas Interaction Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Studio preview canvas a clear, mode-based input model: click any visible caption to select it, pan the reframed video only via an explicit toggle, navigate the zoomed canvas with left-drag, and scrub the timeline with horizontal scroll.

**Architecture:** A new transient `StudioModel.panVideoMode` flag plus a restructured canvas ZStack arbitrate left-drags by z-order (pan-video > selected-block handles > camera > click-to-select > navigate). Two small new SwiftUI layers (`TextSelectHitLayer`, `CanvasNavigationLayer`) replace the bare deselect layer, and `CanvasEventCatcher` maps horizontal scroll to a pure `scrubbedTime` seek.

**Tech Stack:** Swift 6 (Command Line Tools toolchain only — no Xcode.app), SwiftUI, AppKit (NSEvent monitor), swift-testing.

## Global Constraints

- Toolchain: **Command Line Tools only.** Do NOT bump swift-testing (pinned `0.12.0`) or KeyboardShortcuts (pinned `1.10.0`).
- Build `swift build`; test `swift test`. Keep all existing tests green (currently 134 after the bug-fix commits — see Pre-req).
- `panVideoMode` is transient UI state — NOT persisted to `edit.json`, NOT added to `EditState`.
- `cropPannable == hasReframeCanvas == (cropAspect != .original)`.
- Commit messages in normal English, end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Never commit without explicit user confirmation** (project rule). Commit steps below are the intended boundaries; pause for confirmation before committing.

## Pre-req: commit the pending bug fixes

The working tree holds two verified, uncommitted bug fixes (stale `TextCacheKey`; frame-aligned caption seek; 134 tests green) touching `StudioModel.swift`, `TextTimeline.swift`, `CameraCompositor.swift`, and two test files. Commit them first (with user confirmation) so task commits below stay clean:

```bash
git add Sources/CaptureStudio/Studio/CameraCompositor.swift Sources/CaptureStudio/Studio/TextTimeline.swift Sources/CaptureStudio/Studio/StudioModel.swift Tests/CaptureStudioTests/TextCacheKeyTests.swift Tests/CaptureStudioTests/TextTimelineTests.swift
git commit -m "fix: caption stale-cache on resize/wrap and one-frame-late seek

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

## File map

- `Sources/CaptureStudio/Studio/StudioModel.swift` — `panVideoMode` flag, `scrubbedTime` static, reset in `setCropAspect`.
- `Sources/CaptureStudio/Studio/CanvasNavigationLayer.swift` (new) — bottom canvas layer: tap deselects, left-drag pans inspection.
- `Sources/CaptureStudio/Studio/TextSelectHitLayer.swift` (new) — click a visible caption to select it.
- `Sources/CaptureStudio/Studio/CropPanOverlay.swift` — always hit-test (mounted only in pan mode now).
- `Sources/CaptureStudio/Studio/StudioWindow.swift` — canvas ZStack restructure + reframe pan toggle.
- `Sources/CaptureStudio/Studio/CanvasEventCatcher.swift` — horizontal-scroll scrub.
- `Tests/CaptureStudioTests/ScrubMathTests.swift` (new) — `scrubbedTime` unit tests.

---

### Task 1: `scrubbedTime` pure helper

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (add a static func near the other timeline helpers)
- Test: `Tests/CaptureStudioTests/ScrubMathTests.swift` (new)

**Interfaces:**
- Produces: `static func StudioModel.scrubbedTime(from current: Double, scrollDX dx: CGFloat, viewWidth: CGFloat, duration: Double) -> Double` — clamped to `[0, duration]`; `current - (dx/viewWidth)·duration`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CaptureStudioTests/ScrubMathTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import CaptureStudio

@Suite struct ScrubMathTests {
    @Test func swipeRightRewinds() {
        // Positive dx (swipe right) moves backward in time.
        let t = StudioModel.scrubbedTime(from: 5.0, scrollDX: 100, viewWidth: 1000, duration: 10)
        #expect(t == 4.0)   // 5 - (100/1000)*10
    }

    @Test func swipeLeftAdvances() {
        let t = StudioModel.scrubbedTime(from: 5.0, scrollDX: -200, viewWidth: 1000, duration: 10)
        #expect(t == 7.0)   // 5 - (-200/1000)*10
    }

    @Test func clampsToBounds() {
        #expect(StudioModel.scrubbedTime(from: 0.5, scrollDX: 5000, viewWidth: 1000, duration: 10) == 0)
        #expect(StudioModel.scrubbedTime(from: 9.5, scrollDX: -5000, viewWidth: 1000, duration: 10) == 10)
    }

    @Test func zeroWidthOrDurationIsNoop() {
        #expect(StudioModel.scrubbedTime(from: 3, scrollDX: 100, viewWidth: 0, duration: 10) == 3)
        #expect(StudioModel.scrubbedTime(from: 3, scrollDX: 100, viewWidth: 1000, duration: 0) == 3)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ScrubMathTests`
Expected: FAIL — `type 'StudioModel' has no member 'scrubbedTime'` (compile error).

- [ ] **Step 3: Implement the helper**

In `StudioModel.swift`, immediately after the `compositionFrameRate` constant (added by a prior commit, near `static let defaultTextWidth = 3.0`), add:

```swift
    /// New playhead time after a horizontal scroll of `dx` view points across a
    /// canvas `viewWidth` wide; a full-width scroll spans the whole `duration`.
    /// Positive `dx` (swipe right) rewinds; negative advances. Clamped to clip.
    static func scrubbedTime(from current: Double, scrollDX dx: CGFloat,
                             viewWidth: CGFloat, duration: Double) -> Double {
        guard viewWidth > 0, duration > 0 else { return current }
        let delta = Double(dx / viewWidth) * duration
        return min(max(0, current - delta), duration)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ScrubMathTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift Tests/CaptureStudioTests/ScrubMathTests.swift
git commit -m "feat: add scrubbedTime helper for horizontal-scroll timeline scrubbing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `panVideoMode` state + reframe pan toggle

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (add `@Published var panVideoMode`; reset in `setCropAspect`)
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` (`reframeControls`)

**Interfaces:**
- Produces: `StudioModel.panVideoMode: Bool` (`@Published`, default false). A toggle button in the reframe group flips it; it auto-resets to false when the reframe is not pannable.

This task is UI glue. Deliverable: `swift build` succeeds, `swift test` stays green, the toggle appears in the reframe group (disabled unless `cropPannable`). The toggle has no canvas effect yet — Task 3 wires the overlay to it. That intermediate state is expected and compiles.

- [ ] **Step 1: Add the published flag**

In `StudioModel.swift`, immediately after `@Published var currentTime: Double = 0` (line ~29), add:

```swift
    /// Transient: while true, dragging the preview pans the reframed video
    /// (see CropPanOverlay). Not persisted; reset when the reframe isn't pannable.
    @Published var panVideoMode = false
```

- [ ] **Step 2: Reset the flag when the reframe stops being pannable**

In `setCropAspect(_:)`, after `cropAspect = aspect` (line ~1062), add a reset:

```swift
    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        if !cropPannable { panVideoMode = false }
        templateGuideVisible = (aspect == .nineBySixteenTemplate)
```

(Leave the rest of the function unchanged.)

- [ ] **Step 3: Add the toggle to the reframe tool group**

In `StudioWindow.swift`, in `reframeControls`, immediately after the reframe
aspect `Menu { ... }.help("Reframe aspect ratio")` block (before the
`templateGuideVisible` toggle), add:

```swift
        Toggle(isOn: Binding(get: { model.panVideoMode },
                             set: { model.panVideoMode = $0 })) {
            Image(systemName: "hand.draw")
        }
        .toggleStyle(.button)
        .disabled(!model.cropPannable)
        .help("Move/pan the reframed video — drag the canvas to reposition it")
```

- [ ] **Step 4: Build and test**

Run: `swift build && swift test`
Expected: build succeeds; all tests green. The toggle is visible in the reframe group and enabled only when a reframe aspect is set.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "feat: add pan-video mode toggle to the reframe tools

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Canvas layering — click-to-select, navigation drag, pan-mode overlay

**Files:**
- Create: `Sources/CaptureStudio/Studio/CanvasNavigationLayer.swift`
- Create: `Sources/CaptureStudio/Studio/TextSelectHitLayer.swift`
- Modify: `Sources/CaptureStudio/Studio/CropPanOverlay.swift:30` (the `.allowsHitTesting` line)
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` (the inner canvas `ZStack`, lines ~57-81)

**Interfaces:**
- Consumes: `model.panVideoMode` (Task 2); `model.selectTextBlock(_:)`, `model.deselectAll()`, `model.panCanvas(by:)`, `model.currentTime`, `model.textBlocks`, `model.renderSize`; `TextTimeline.active(at:blocks:)`; `TextImageRenderer.size(_:canvas:)`; `CropMath.aspectFitRect(_:in:)`.
- Produces: new canvas drag arbitration (pan-video > selected-block > camera > click-select > navigate).

UI glue. Deliverable: `swift build` + `swift test` green, and the behaviors present (verified in Task 5 smoke).

- [ ] **Step 1: Create `CanvasNavigationLayer.swift`**

```swift
import SwiftUI

/// Bottom-most canvas input layer: a tap deselects everything; a left-drag pans
/// the zoomed inspection view (content follows the cursor), mirroring the
/// trackpad/middle-drag navigation in `CanvasEventCatcher`. It sits at the
/// bottom of the canvas ZStack, so block move/resize, pan-video, and
/// text-select all take priority — this only runs on empty canvas. Panning is a
/// no-op at fit zoom. Uses the global coordinate space so the inspection
/// transform doesn't feed back into the drag.
struct CanvasNavigationLayer: View {
    @ObservedObject var model: StudioModel
    @State private var lastTranslation: CGSize = .zero

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { model.deselectAll() }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let dx = value.translation.width - lastTranslation.width
                        let dy = value.translation.height - lastTranslation.height
                        lastTranslation = value.translation
                        model.panCanvas(by: CGSize(width: dx, height: dy))
                    }
                    .onEnded { _ in lastTranslation = .zero }
            )
    }
}
```

- [ ] **Step 2: Create `TextSelectHitLayer.swift`**

```swift
import SwiftUI

/// Invisible tap targets over every caption visible at the playhead, so a click
/// on a box selects it — the same selection a timeline-block tap makes. Targets
/// are rendered in array (z) order, so for overlapping boxes the topmost is
/// frontmost and wins the tap (SwiftUI hit-tests front-to-back). Sits above the
/// navigation layer (a box tap selects rather than deselects) and below the
/// selected block's `TextCanvasOverlay` (that block keeps its move/resize).
struct TextSelectHitLayer: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        GeometryReader { geo in
            if model.renderSize.width > 0 {
                let videoRect = CropMath.aspectFitRect(model.renderSize, in: geo.size)
                let viewScale = videoRect.width / model.renderSize.width
                ForEach(activeBlocks) { block in
                    let frame = boxFrame(block, videoRect: videoRect, viewScale: viewScale)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .onTapGesture { model.selectTextBlock(block.id) }
                }
            }
        }
    }

    /// Captions visible at the playhead, in array (z) order (later = on top).
    private var activeBlocks: [TextBlock] {
        TextTimeline.active(at: model.currentTime, blocks: model.textBlocks)
    }

    private func boxFrame(_ block: TextBlock, videoRect: CGRect, viewScale: CGFloat) -> CGRect {
        let measured = TextImageRenderer.size(block, canvas: model.renderSize)
        let w = max(measured.width * viewScale, 24)
        let h = max(measured.height * viewScale, 16)
        let cx = videoRect.minX + CGFloat(block.centerX) * model.renderSize.width * viewScale
        let cy = videoRect.minY + CGFloat(block.centerY) * model.renderSize.height * viewScale
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}
```

- [ ] **Step 3: CropPanOverlay — always hit-test (it is mounted only in pan mode now)**

In `CropPanOverlay.swift`, change line 30:

```swift
        .allowsHitTesting(model.cropPannable)
```

to:

```swift
        .allowsHitTesting(true)
```

- [ ] **Step 4: Restructure the canvas ZStack**

In `StudioWindow.swift`, replace the inner canvas `ZStack` (the one starting
`ZStack {` at line ~58 with `PlayerView(player: player)` and ending at
`ReelsSafeAreaOverlay(model: model)` before `.scaleEffect`):

```swift
                ZStack {
                    PlayerView(player: player)
                    // Click empty canvas to deselect.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.deselectAll() }
                    if model.cropPannable {
                        CropPanOverlay(model: model)
                    }
                    if model.showsCameraOverlay {
                        CameraPipOverlay(model: model)
                    }
                    if model.selectedTextBlock != nil {
                        TextCanvasOverlay(model: model)
                    }
                    // Topmost: reels safe-area guide (studio-only).
                    ReelsSafeAreaOverlay(model: model)
                }
```

with:

```swift
                ZStack {
                    PlayerView(player: player)
                    // Bottom: tap deselects, left-drag pans the inspection view.
                    CanvasNavigationLayer(model: model)
                    // Click a visible caption to select it (above navigation).
                    TextSelectHitLayer(model: model)
                    if model.showsCameraOverlay {
                        CameraPipOverlay(model: model)
                    }
                    if model.selectedTextBlock != nil {
                        TextCanvasOverlay(model: model)
                    }
                    // Reels safe-area guide (studio-only).
                    ReelsSafeAreaOverlay(model: model)
                    // Pan-video mode: a top grab layer that wins all drags in the
                    // video rect while the mode is on.
                    if model.panVideoMode {
                        CropPanOverlay(model: model)
                    }
                }
```

- [ ] **Step 5: Build and test**

Run: `swift build && swift test`
Expected: build succeeds; all tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/Studio/CanvasNavigationLayer.swift Sources/CaptureStudio/Studio/TextSelectHitLayer.swift Sources/CaptureStudio/Studio/CropPanOverlay.swift Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "feat: click-to-select captions, navigation drag, and pan-mode-gated video pan

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Horizontal-scroll timeline scrub

**Files:**
- Modify: `Sources/CaptureStudio/Studio/CanvasEventCatcher.swift:66-78` (the `.scrollWheel` case)

**Interfaces:**
- Consumes: `StudioModel.scrubbedTime(...)` (Task 1), `model.seek(to:)`, `model.duration`, `model.currentTime`, `model.canvasZoomed`, `model.panCanvas(by:)`.
- Produces: horizontal scroll scrubs the timeline; vertical scroll pans the zoomed inspection view; ⌘-scroll still zooms.

UI glue. Deliverable: `swift build` + `swift test` green; behavior verified in Task 5 smoke.

- [ ] **Step 1: Replace the `.scrollWheel` case**

In `CanvasEventCatcher.swift`, replace the existing `.scrollWheel` case
(lines ~66-78):

```swift
        case .scrollWheel:
            if event.modifierFlags.contains(.command) {
                // ⌘-scroll zooms — mouse-wheel users have no pinch gesture.
                let line = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY
                                                           : event.scrollingDeltaY * 3
                model.zoomCanvas(by: 1 + line * 0.005)
                return nil
            }
            guard model.canvasZoomed else { return event }
            // Document-scroll feel: content follows the scroll delta.
            model.panCanvas(by: CGSize(width: event.scrollingDeltaX,
                                       height: event.scrollingDeltaY))
            return nil
```

with:

```swift
        case .scrollWheel:
            if event.modifierFlags.contains(.command) {
                // ⌘-scroll zooms — mouse-wheel users have no pinch gesture.
                let line = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY
                                                           : event.scrollingDeltaY * 3
                model.zoomCanvas(by: 1 + line * 0.005)
                return nil
            }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if abs(dx) > abs(dy) {
                // Horizontal scroll scrubs the timeline.
                model.seek(to: StudioModel.scrubbedTime(from: model.currentTime,
                                                        scrollDX: dx,
                                                        viewWidth: bounds.width,
                                                        duration: model.duration))
                return nil
            }
            // Vertical scroll pans the zoomed inspection view (content follows).
            guard model.canvasZoomed else { return event }
            model.panCanvas(by: CGSize(width: 0, height: dy))
            return nil
```

- [ ] **Step 2: Build and test**

Run: `swift build && swift test`
Expected: build succeeds; all tests green.

- [ ] **Step 3: Commit**

```bash
git add Sources/CaptureStudio/Studio/CanvasEventCatcher.swift
git commit -m "feat: scrub the timeline with horizontal scroll over the canvas

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Full verification + manual smoke

**Files:** none (verification only).

- [ ] **Step 1: Full build + test**

Run: `swift build && swift test`
Expected: build succeeds; all tests pass (134 prior + 4 new `ScrubMathTests`).

- [ ] **Step 2: Package and launch**

Run: `scripts/build-app.sh debug && pkill -x CaptureStudio; open dist/CaptureStudio.app`
Expected: the app launches from the menu bar.

- [ ] **Step 3: Manual smoke checklist**

Open a recording in Studio and confirm:
- With two captions visible at the playhead, click each on the canvas → it
  selects (inline caption field shows its text); overlapping → topmost selects.
- Click empty canvas → deselects.
- Set a reframe aspect (e.g. a crop) → the `hand.draw` toggle in the reframe
  group enables. Turn it on → dragging the canvas pans the video; turn it off →
  dragging no longer pans the video.
- With nothing selected and pan mode off, zoom in (⌘-scroll or pinch) then
  left-drag → the zoomed view pans; at fit zoom, left-drag does nothing.
- Two-finger horizontal scroll over the canvas → the playhead scrubs
  (left/right move through the clip); vertical scroll while zoomed pans;
  ⌘-scroll still zooms.
- Switch the reframe back to Original → the pan toggle disables and turns off.

- [ ] **Step 4: Optional docs refresh**

If smoke passes, note the new canvas interactions (click-to-select captions,
pan-video toggle, horizontal-scroll scrub) in `CLAUDE.md` / `README` where the
Studio canvas is described. Commit separately:

```bash
git add CLAUDE.md README.md
git commit -m "docs: describe canvas click-select, pan-video toggle, and scroll scrub

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review notes

- **Spec coverage:** #1 click-to-select → Task 3 (`TextSelectHitLayer`). #2 pan-video toggle → Task 2 (flag + button) + Task 3 (overlay gated on `panVideoMode`, raised to top). #3 navigation drag → Task 3 (`CanvasNavigationLayer`); horizontal-scroll scrub → Task 1 (`scrubbedTime`) + Task 4 (`CanvasEventCatcher`).
- **Build-green ordering:** Task 2 adds `panVideoMode` (unused until Task 3) — compiles. Task 3 introduces the two layers and rewires the ZStack in one commit. Task 4 is independent of 2/3.
- **Type consistency:** `panVideoMode`, `scrubbedTime(from:scrollDX:viewWidth:duration:)`, `CanvasNavigationLayer`, `TextSelectHitLayer` names match across tasks. `CropMath.aspectFitRect`, `TextImageRenderer.size`, `TextTimeline.active` exist today.
- **Gesture-arbitration risk:** click-to-select is active only when pan mode is off (the pan overlay covers the video rect when on) — accepted in the spec. Verified in Task 5 smoke.
