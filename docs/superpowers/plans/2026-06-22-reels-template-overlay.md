# "9:16 with template" reels frame overlay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "9:16 with template" aspect option that *fits* (letterboxes) any source into a 9:16 canvas and shows a studio-only TikTok safe-area guide that never touches the export.

**Architecture:** New `CropAspect` case with `isFit` (contain) semantics drives a 9:16 canvas + letterbox in both render paths. The guide (canvas border + 3 safe-zone boxes) is a pure SwiftUI overlay toggled by ephemeral `templateGuideVisible`. Spec: `docs/superpowers/specs/2026-06-22-reels-template-overlay-design.md`.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation video composition, Core Image (`StudioCompositor`), swift-testing.

## Global Constraints

- Command Line Tools toolchain only — do NOT bump swift-testing (`0.12.0`) or KeyboardShortcuts (`1.10.0`).
- `swift build` + `swift test` must stay green (109 tests currently).
- Plain `.nineBySixteen` (cover/crop) must remain unchanged.
- The guide and canvas border are studio-only — never rendered into the composition/export.
- Pure helpers get swift-testing tests; UI glue (overlay view, toolbar) is not unit-tested, per project convention.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Never push without explicit user confirmation.

---

## File Structure

- `Sources/CaptureStudio/ProjectBundle/EditState.swift` — add `CropAspect.nineBySixteenTemplate` + `isFit`.
- `Sources/CaptureStudio/Studio/StudioModel.swift` — `hasReframeCanvas`/`cropPannable`, fit-aware `cropRectInSource`, `templateGuideVisible`, `setCropAspect`, render-guard + export-canvas remap.
- `Sources/CaptureStudio/Studio/CameraCompositor.swift` — `CompositorLayout.fitScreen`, letterbox screen placement, fit-aware cursor/click mapping.
- `Sources/CaptureStudio/Studio/ReelsSafeAreaOverlay.swift` — NEW studio-only guide overlay.
- `Sources/CaptureStudio/Studio/StudioWindow.swift` — wire overlay into `canvas()`, add toggle button, remap `cropActive`→`cropPannable` in pan/slider gating.
- `Tests/CaptureStudioTests/` — new tests for `CropAspect`, fit geometry, model gating.

---

## Task 1: `CropAspect` fit case + `isFit`

**Files:**
- Modify: `Sources/CaptureStudio/ProjectBundle/EditState.swift:6-29`
- Test: `Tests/CaptureStudioTests/CropAspectTests.swift` (create)

**Interfaces:**
- Produces: `CropAspect.nineBySixteenTemplate` (rawValue `"9:16 with template"`), `CropAspect.isFit: Bool`, `CropAspect.ratio` returns `9.0/16.0` for it, `displayName` returns the rawValue.

- [ ] **Step 1: Write the failing test**

Create `Tests/CaptureStudioTests/CropAspectTests.swift`:

```swift
import Testing
import Foundation
@testable import CaptureStudio

struct CropAspectTests {
    @Test func templateRatioMatchesNineBySixteen() {
        #expect(CropAspect.nineBySixteenTemplate.ratio == 9.0 / 16.0)
        #expect(CropAspect.nineBySixteen.ratio == 9.0 / 16.0)
    }

    @Test func onlyTemplateIsFit() {
        #expect(CropAspect.nineBySixteenTemplate.isFit == true)
        for a in CropAspect.allCases where a != .nineBySixteenTemplate {
            #expect(a.isFit == false)
        }
    }

    @Test func templateDisplayNameIsRawValue() {
        #expect(CropAspect.nineBySixteenTemplate.displayName == "9:16 with template")
    }

    @Test func templateDecodesFromRawValue() {
        #expect(CropAspect(rawValue: "9:16 with template") == .nineBySixteenTemplate)
    }
}
```

- [ ] **Step 2: Run test, verify it fails**

Run: `swift test --filter CropAspectTests`
Expected: FAIL — `nineBySixteenTemplate` / `isFit` not defined.

- [ ] **Step 3: Implement**

In `EditState.swift`, edit `CropAspect`:

```swift
enum CropAspect: String, Codable, CaseIterable, Equatable {
    case original
    case nineBySixteen = "9:16"
    case nineBySixteenTemplate = "9:16 with template"
    case square = "1:1"
    case fourByFive = "4:5"
    case sixteenByNine = "16:9"
    case fourByThree = "4:3"

    /// Width / height of the output canvas; nil for `original`.
    var ratio: Double? {
        switch self {
        case .original: return nil
        case .nineBySixteen, .nineBySixteenTemplate: return 9.0 / 16.0
        case .square: return 1.0
        case .fourByFive: return 4.0 / 5.0
        case .sixteenByNine: return 16.0 / 9.0
        case .fourByThree: return 4.0 / 3.0
        }
    }

    /// Contain (fit/letterbox) the source instead of cover (crop). Only the
    /// template aspect fits; every other aspect crops to fill.
    var isFit: Bool { self == .nineBySixteenTemplate }

    var displayName: String {
        self == .original ? "Original" : rawValue
    }
}
```

- [ ] **Step 4: Run test, verify pass**

Run: `swift test --filter CropAspectTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/ProjectBundle/EditState.swift Tests/CaptureStudioTests/CropAspectTests.swift
git commit -m "feat: add 9:16-with-template CropAspect case (fit semantics)"
```

---

## Task 2: Model gating — fit canvas without crop, guide state

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (lines `149`, `172`, `1015-1029`, `1094`, `1371`, `1406-1417`; add published prop near `145-149`)
- Test: `Tests/CaptureStudioTests/StudioModelFitTests.swift` (create)

**Interfaces:**
- Consumes: `CropAspect.isFit`, `CropAspect.ratio` (Task 1).
- Produces: `StudioModel.hasReframeCanvas: Bool`, `StudioModel.cropPannable: Bool`, `@Published var templateGuideVisible: Bool`, fit-aware `cropRectInSource` (nil when `isFit`), `setCropAspect` sets `templateGuideVisible`.

Note: most model paths that branch on geometry are not unit-testable (need an AVAsset). The pure-ish gating below is tested via a lightweight helper. Where a property reads `sourceSize` (set only after load), tests set it through the existing init path is not possible — instead test the pure enum-driven booleans that don't need a loaded asset.

- [ ] **Step 1: Write the failing test**

Create `Tests/CaptureStudioTests/StudioModelFitTests.swift`. These assert the canvas-size math (pure, on `CropAspect`) that fit mode relies on:

```swift
import Testing
import CoreGraphics
@testable import CaptureStudio

struct StudioModelFitTests {
    // 9:16 canvas at 1080 short side is portrait 1080x1920.
    @Test func templateCanvasIsPortrait1080() {
        let ratio = CropAspect.nineBySixteenTemplate.ratio!
        let shortSide: CGFloat = 1080
        let height = (CGFloat(1.0) / CGFloat(ratio) * shortSide / 2).rounded() * 2
        #expect(shortSide == 1080)
        #expect(height == 1920)
    }
}
```

(`canvasSize` is `private`; this test pins the ratio→canvas math it depends on. The model wiring is verified by the build + manual smoke in Task 8.)

- [ ] **Step 2: Run test, verify it fails or passes-trivially**

Run: `swift test --filter StudioModelFitTests`
Expected: PASS once Task 1 is in (depends only on `ratio`). If `nineBySixteenTemplate` missing → FAIL to compile. This task's real verification is `swift build`.

- [ ] **Step 3: Implement model changes**

3a. Add the published guide flag beside the crop state (`StudioModel.swift:148`):

```swift
    var cropActive: Bool { cropAspect != .original }   // keep name; redefine below

    /// A non-source output canvas is in play (any reframe — crop OR fit).
    var hasReframeCanvas: Bool { cropAspect != .original }

    /// User can pan/zoom the crop. False in fit mode (nothing to pan).
    var cropPannable: Bool { hasReframeCanvas && !cropAspect.isFit }

    /// Studio-only reels safe-area guide visibility. Ephemeral (never persisted,
    /// never exported); auto-on when the template aspect is selected.
    @Published var templateGuideVisible = false
```

Then DELETE the old `cropActive` line (the redundant first line above) — every remaining `cropActive` reference is remapped in steps below. Search-and-replace per site:

3b. `renderSize` (`:172`): `if cropActive` → `if hasReframeCanvas`.

3c. `cropRectInSource` (`:1015-1019`): add the fit guard:

```swift
    var cropRectInSource: CGRect? {
        guard let ratio = cropAspect.ratio, !cropAspect.isFit,
              sourceSize.width > 0 else { return nil }
        return CropMath.cropRect(source: sourceSize, ratio: ratio, zoom: cropZoom,
                                 centerX: cropCenterX, centerY: cropCenterY)
    }
```

3d. `setCropAspect` (`:1021-1029`): set the guide flag:

```swift
    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        templateGuideVisible = (aspect == .nineBySixteenTemplate)
        cropCenterX = 0.5
        cropCenterY = 0.5
        cropZoom = 1.0
        refreshPlayerItemForCanvasChange()
        applyVideoComposition()
        saveEdit()
    }
```

3e. `buildVideoComposition` guard (`:1094`): `cropActive` → `hasReframeCanvas`.

3f. Export branch (`:1371`): `if cropActive` → `if hasReframeCanvas`.

3g. `exportCanvasSize` `.source` case (`:1412-1415`): fit mode keeps native long-side resolution:

```swift
        case .source:
            if cropAspect.isFit {
                let longSide = max(sourceSize.width, sourceSize.height)
                let shortSide = (longSide * 9.0 / 16.0 / 2).rounded() * 2
                return canvasSize(shortSide: shortSide) ?? sourceSize
            }
            guard let crop = cropRectInSource else { return sourceSize }
            return CGSize(width: (crop.width / 2).rounded(.down) * 2,
                          height: (crop.height / 2).rounded(.down) * 2)
```

(`canvasSize` is private to the model — this edit is inside the model, so it is in scope.)

- [ ] **Step 4: Run build + tests**

Run: `swift build && swift test --filter StudioModelFitTests && swift test --filter CropAspectTests`
Expected: build OK, tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift Tests/CaptureStudioTests/StudioModelFitTests.swift
git commit -m "feat: model gating for fit-mode 9:16 canvas + guide state"
```

---

## Task 3: Letterbox in the layer-instruction render path

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift:1128-1139` (screen layer transform)

**Interfaces:**
- Consumes: `CropAspect.isFit`, `CropMath.aspectFitRect`, `sourceSize`, `cropRectInSource`.
- Produces: screen layer letterboxed (contain) when `cropAspect.isFit`.

- [ ] **Step 1: Implement the fit branch**

Replace the screen-layer transform block (`:1128-1139`):

```swift
        let screenLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: screenTrack)
        if cropAspect.isFit {
            // Contain: scale source to fit the canvas, centered; renderSize's
            // default black background fills the letterbox bars.
            let fit = CropMath.aspectFitRect(sourceSize, in: canvas)
            if fit.width > 0, sourceSize.width > 0 {
                let s = fit.width / sourceSize.width
                screenLayer.setTransform(
                    CGAffineTransform(scaleX: s, y: s)
                        .concatenating(CGAffineTransform(translationX: fit.minX,
                                                         y: fit.minY)),
                    at: .zero
                )
            }
        } else if let crop = cropRectInSource, crop.width > 0 {
            // Scale so the crop fills the canvas, then shift its origin to 0.
            let s = canvas.width / crop.width
            screenLayer.setTransform(
                CGAffineTransform(scaleX: s, y: s)
                    .concatenating(CGAffineTransform(translationX: -crop.minX * s,
                                                     y: -crop.minY * s)),
                at: .zero
            )
        }
        layers.append(screenLayer)
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: OK.

- [ ] **Step 3: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift
git commit -m "feat: letterbox screen in fit mode (layer-instruction path)"
```

---

## Task 4: Letterbox + cursor fix in the compositor path

**Files:**
- Modify: `Sources/CaptureStudio/Studio/CameraCompositor.swift` — `CompositorLayout` (`:9-…`), `screenCanvasImage` (`:300-311`), `sourceToCanvas`/`cursorScale` (`:420-435`)
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift:1159-1165` (set `layout.fitScreen`)

**Interfaces:**
- Consumes: `CropAspect.isFit`, `CropMath.aspectFitRect`.
- Produces: `CompositorLayout.fitScreen: Bool`; compositor letterboxes screen and maps cursor/click through the contain transform.

- [ ] **Step 1: Add `fitScreen` to the layout struct**

In `CameraCompositor.swift`, add to `CompositorLayout` (near the screen fields, after `screenCrop`):

```swift
    /// Contain (letterbox) the screen into the canvas instead of cover/crop.
    /// Set for the "9:16 with template" aspect. When true, `screenCrop` is nil.
    var fitScreen = false
```

- [ ] **Step 2: Set it where the layout is built**

In `StudioModel.buildCompositorComposition` (`:1159-1165`), after constructing `layout`:

```swift
        layout.fitScreen = cropAspect.isFit
```

- [ ] **Step 3: Letterbox the screen image**

Replace `screenCanvasImage` (`:300-311`):

```swift
    private func screenCanvasImage(_ buffer: CVPixelBuffer,
                                   layout: CompositorLayout) -> CIImage {
        let image = CIImage(cvPixelBuffer: buffer)
        if layout.fitScreen {
            // Contain (letterbox) the whole source, centered, over black.
            let fit = CropMath.aspectFitRect(layout.sourceSize, in: layout.canvas)
            guard fit.width > 0, layout.sourceSize.width > 0 else { return image }
            let s = fit.width / layout.sourceSize.width
            let ty = layout.canvas.height - fit.maxY    // top-left → CI bottom-left
            let fitted = image
                .transformed(by: CGAffineTransform(scaleX: s, y: s)
                    .concatenating(CGAffineTransform(translationX: fit.minX, y: ty)))
                .cropped(to: CGRect(origin: .zero, size: layout.canvas))
            let black = CIImage(color: .black)
                .cropped(to: CGRect(origin: .zero, size: layout.canvas))
            return fitted.composited(over: black)
        }
        let crop = layout.screenCrop ?? CGRect(origin: .zero, size: layout.sourceSize)
        guard crop.width > 0 else { return image }
        let cropCI = Self.flip(crop, in: layout.sourceSize.height)
        let scale = layout.canvas.width / crop.width
        let t = CGAffineTransform(translationX: -cropCI.minX, y: -cropCI.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return image.cropped(to: cropCI).transformed(by: t)
            .cropped(to: CGRect(origin: .zero, size: layout.canvas))
    }
```

- [ ] **Step 4: Make cursor/click mapping fit-aware**

Replace `sourceToCanvas` and `cursorScale` (`:420-435`) with a unified screen-placement helper:

```swift
    /// Top-left rect (canvas px) the full source maps into, for either fit
    /// (letterbox) or cover (crop) placement. Cursor/click overlays ride this
    /// so they land on the screen content, not the raw canvas.
    private static func screenPlacement(_ layout: CompositorLayout) -> (scale: CGFloat, origin: CGPoint) {
        if layout.fitScreen {
            let fit = CropMath.aspectFitRect(layout.sourceSize, in: layout.canvas)
            let s = layout.sourceSize.width > 0 ? fit.width / layout.sourceSize.width : 1
            return (s, fit.origin)
        }
        let crop = layout.screenCrop ?? CGRect(origin: .zero, size: layout.sourceSize)
        let s = crop.width > 0 ? layout.canvas.width / crop.width : 1
        return (s, CGPoint(x: -crop.minX * s, y: -crop.minY * s))
    }

    /// Screen-source pixel point → canvas pixel point (top-left origin).
    private static func sourceToCanvas(_ p: CGPoint, layout: CompositorLayout) -> CGPoint {
        let pl = screenPlacement(layout)
        return CGPoint(x: pl.origin.x + p.x * pl.scale, y: pl.origin.y + p.y * pl.scale)
    }

    /// Canvas pixels per screen point (glyph sizing).
    private static func cursorScale(_ layout: CompositorLayout) -> CGFloat {
        screenPlacement(layout).scale * layout.sourcePerPoint
    }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: OK.

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/Studio/CameraCompositor.swift Sources/CaptureStudio/Studio/StudioModel.swift
git commit -m "feat: letterbox + fit-aware cursor mapping in compositor"
```

---

## Task 5: `ReelsSafeAreaOverlay` studio-only guide

**Files:**
- Create: `Sources/CaptureStudio/Studio/ReelsSafeAreaOverlay.swift`
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift:66-71` (add to ZStack, topmost)

**Interfaces:**
- Consumes: `model.renderSize`, `model.cropAspect`, `model.templateGuideVisible`, `CropMath.aspectFitRect`.
- Produces: `ReelsSafeAreaOverlay(model:)` view.

- [ ] **Step 1: Create the overlay view**

Create `Sources/CaptureStudio/Studio/ReelsSafeAreaOverlay.swift`:

```swift
import SwiftUI

/// Studio-only TikTok/Reels safe-area guide for the "9:16 with template"
/// aspect. Draws a dashed canvas border plus translucent boxes marking where
/// the platform's own chrome (top tabs, right action column, bottom caption /
/// nav) covers content, so the user keeps captions / camera clear of it.
///
/// Purely visual: `allowsHitTesting(false)`, never part of the composition or
/// export. A SwiftUI layer ON TOP of the player, like `TextCanvasOverlay`.
struct ReelsSafeAreaOverlay: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        GeometryReader { geo in
            if model.cropAspect == .nineBySixteenTemplate,
               model.templateGuideVisible,
               model.renderSize.width > 0 {
                let rect = CropMath.aspectFitRect(model.renderSize, in: geo.size)
                ZStack(alignment: .topLeading) {
                    // Safe-zone boxes (fractions of the 9:16 content rect).
                    zone(rect, x: 0,    y: 0,    w: 1,    h: 0.08)   // top tabs bar
                    zone(rect, x: 0.85, y: 0.45, w: 0.15, h: 0.47)  // right actions
                    zone(rect, x: 0,    y: 0.78, w: 0.75, h: 0.22)  // bottom caption/nav

                    // Canvas border — the reels frame boundary (studio-only).
                    Rectangle()
                        .strokeBorder(Color.accentColor,
                                      style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// One translucent safe-zone box, placed by normalized fractions of `rect`.
    private func zone(_ rect: CGRect, x: CGFloat, y: CGFloat,
                      w: CGFloat, h: CGFloat) -> some View {
        let frame = CGRect(x: rect.minX + x * rect.width,
                           y: rect.minY + y * rect.height,
                           width: w * rect.width, height: h * rect.height)
        return RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}
```

- [ ] **Step 2: Wire into the canvas ZStack (topmost)**

In `StudioWindow.swift`, in `canvas(player:)`, add after the `TextCanvasOverlay` block (`:69-71`), still inside the inner `ZStack` that gets `scaleEffect`:

```swift
                    if model.selectedTextBlock != nil {
                        TextCanvasOverlay(model: model)
                    }
                    // Topmost: reels safe-area guide (studio-only).
                    ReelsSafeAreaOverlay(model: model)
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: OK.

- [ ] **Step 4: Commit**

```bash
git add Sources/CaptureStudio/Studio/ReelsSafeAreaOverlay.swift Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "feat: reels safe-area guide overlay (studio-only)"
```

---

## Task 6: Toolbar toggle + pan-gating remap

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift:63`, `:212-244` (reframeControls)
- Modify: `Sources/CaptureStudio/Studio/CropPanOverlay.swift:14,28`

**Interfaces:**
- Consumes: `model.templateGuideVisible`, `model.cropAspect`, `model.cropPannable`.
- Produces: a guide-toggle button in the reframe tool group; pan overlay + zoom slider gated on `cropPannable`.

- [ ] **Step 1: Add the toggle button + gate the slider on `cropPannable`**

In `reframeControls` (`:212-244`), after the aspect `Menu { … }.help("Reframe aspect ratio")` and before the crop-zoom `if`:

```swift
        Toggle(isOn: Binding(get: { model.templateGuideVisible },
                             set: { model.templateGuideVisible = $0 })) {
            Image(systemName: "rectangle.dashed")
        }
        .toggleStyle(.button)
        .disabled(model.cropAspect != .nineBySixteenTemplate)
        .help("Toggle reels safe-area guide")

        if model.cropPannable {
```

(Change the existing `if model.cropActive {` that wraps the zoom slider to `if model.cropPannable {`.)

- [ ] **Step 2: Gate the canvas crop-pan overlay on `cropPannable`**

In `StudioWindow.swift:63`: `if model.cropActive {` → `if model.cropPannable {`.

In `CropPanOverlay.swift:14`: `if model.cropActive,` → `if model.cropPannable,`.
In `CropPanOverlay.swift:28`: `.allowsHitTesting(model.cropActive)` → `.allowsHitTesting(model.cropPannable)`.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: OK — no remaining `cropActive` references (it was removed in Task 2).

Run: `grep -rn "cropActive" Sources/`
Expected: no matches.

- [ ] **Step 4: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioWindow.swift Sources/CaptureStudio/Studio/CropPanOverlay.swift
git commit -m "feat: reels guide toggle button + cropPannable pan gating"
```

---

## Task 7: Full build, test, smoke

**Files:** none (verification only)

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: all green (113 = 109 + 4 new).

- [ ] **Step 2: Package + relaunch**

Run: `scripts/build-app.sh debug && pkill -x CaptureStudio; open dist/CaptureStudio.app`
Expected: app launches.

- [ ] **Step 3: Manual smoke (record short clip, open Studio)**

Verify, in order:
1. Aspect menu shows "9:16 with template" (separate from "9:16").
2. Select it on a 16:9 recording → video shrinks to a centered band with black top/bottom bars; dashed border + 3 safe-zone boxes appear; guide button is enabled + on.
3. Toggle the button off → boxes + border hide, letterbox stays. Toggle on → they return.
4. Switch to plain "9:16" → cover crop returns (no bars), border + boxes gone, button disabled.
5. Add a caption in the bottom black bar → it renders in preview.
6. Export → output is clean 9:16 with black bars, NO border/boxes baked in. Cursor (if shown) sits on the screen content, not stretched.

- [ ] **Step 4: Final commit (docs only, if any tweaks)**

```bash
git add -A
git commit -m "docs: reels template plan checkboxes complete"
```

---

## Self-Review

- **Spec coverage:** new aspect list item (T1) ✓; fit/letterbox export both render paths (T3, T4) ✓; canvas border + guide studio-only, topmost, toggle (T5, T6) ✓; switch-away removes bars+border (T2 `setCropAspect`, gating) ✓; button default off+disabled / enabled+on (T6) ✓; cursor correctness under fit (T4) ✓; tests for pure helpers (T1, T2) ✓.
- **Placeholders:** none — every code step is concrete.
- **Type consistency:** `hasReframeCanvas`/`cropPannable`/`templateGuideVisible`/`fitScreen`/`isFit`/`screenPlacement` used identically across tasks. `cropActive` fully removed (T2) and all call sites remapped (T2, T6); T6 Step 3 greps to confirm zero references.
