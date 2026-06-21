# Studio — "9:16 with template" reels frame overlay

**Date:** 2026-06-22
**Status:** Design approved, ready for implementation plan

## Goal

Let a user reframe any recording for TikTok / IG Reels / YT Shorts from the
existing Studio aspect-ratio list. Adds a new aspect option **"9:16 with
template"** that, unlike the existing plain **"9:16"**, *fits* (letterboxes) the
whole source into a 9:16 canvas instead of *cropping* it — and shows a
studio-only safe-area guide so the user can frame content clear of the
platform's own UI chrome.

## Key decisions (locked during brainstorm)

1. **Template chrome is a studio-only guide, never baked into export.** Export =
   clean video + black letterbox bars only. The canvas border and safe-zone
   boxes are preview overlays. (Mirrors the existing "canvas border not in
   export" intent.)
2. **Guide draws simplified safe-zone boxes**, not a full TikTok clone — SwiftUI
   shapes (top tabs bar, right action-button column, bottom caption/nav band).
   No bundled image asset.
3. **Modeling: new `CropAspect` case + fit semantics** (Approach A). The template
   is an item in the aspect list, not a separate orthogonal state machine.

## Two-part split

The feature divides cleanly along the export boundary:

| Part | Affects export? | Where |
|------|-----------------|-------|
| 9:16 **fit / letterbox** (black bars are real output pixels) | **Yes** | `StudioModel` + both composition builders |
| Safe-zone guide + canvas border (toggleable) | **No** | new SwiftUI overlay only |

This split is the core of the design: the guide is a pure overlay and can never
leak into the exported mp4.

## 1. Data model — `EditState.swift`

Extend `CropAspect`:

```swift
enum CropAspect: String, Codable, CaseIterable, Equatable {
    case original
    case nineBySixteen = "9:16"
    case nineBySixteenTemplate = "9:16 with template"   // NEW — fit, not crop
    case square = "1:1"
    case fourByFive = "4:5"
    case sixteenByNine = "16:9"
    case fourByThree = "4:3"

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

    /// Contain (fit, letterbox) instead of cover (crop) for the source layer.
    var isFit: Bool { self == .nineBySixteenTemplate }

    var displayName: String {
        self == .original ? "Original" : rawValue   // "9:16 with template"
    }
}
```

- Plain `.nineBySixteen` is **unchanged** — still cover/crop.
- Existing raw-string decode (`CropAspect.init(rawValue:) ?? .original`) means
  older bundles and unknown future values still degrade to `.original`. New case
  needs no decode change.
- **No new persisted fields.** `cropAspect` already persists in `edit.json`; the
  new case rides that. The guide-visible state is ephemeral (§4).

## 2. Render / fit path — `StudioModel.swift` + composition builders

### Split the overloaded `cropActive`

Today `cropActive = cropAspect != .original` gates four things at once:
renderSize, the crop-pan overlay, the zoom slider, and `cropRectInSource`. The
template needs a 9:16 canvas **without** crop pan. Split into two concepts:

```swift
/// A non-source output canvas is in play (any reframe, fit or crop).
var hasReframeCanvas: Bool { cropAspect != .original }

/// User can pan/zoom the crop. False in fit mode — nothing to pan.
var cropPannable: Bool { hasReframeCanvas && !cropAspect.isFit }
```

Remap the existing call sites:

- `renderSize` → use `hasReframeCanvas` where it currently checks `cropActive`
  (so the template gets a 9:16 `previewCanvasSize`).
- Crop-pan overlay (`CropPanOverlay`), the zoom slider, and `commitCropEdit`
  paths → use `cropPannable` (hidden in fit mode).
- `canvasSize(shortSide:)` already derives from `cropAspect.ratio` (non-nil for
  the template) → returns **1080×1920** for the template, no change needed.

### Contain placement (the one export-affecting change)

```swift
var cropRectInSource: CGRect? {
    guard let ratio = cropAspect.ratio, !cropAspect.isFit,
          sourceSize.width > 0 else { return nil }   // nil in fit mode
    return CropMath.cropRect(...)
}
```

With `screenCrop == nil` and `canvas == 9:16 ≠ sourceSize`, both composition
builders must place the screen layer **contain** (scale-to-fit, centered, black
fill) instead of the current cover behavior:

- **Layer-instruction builder** (`buildVideoComposition(canvasOverride:)`): set a
  layer transform that scales the source to fit the canvas width (for a landscape
  source) and centers it vertically. `renderSize`'s default background is black →
  bars come for free.
- **Compositor builder** (`buildCompositorComposition` / `StudioCompositor`):
  when `screenCrop == nil` and canvas ≠ source, place the screen image with the
  same contain transform.

**Reuse the existing helper** — `CropMath.aspectFitRect(_ content:in:)` already
returns the largest content-aspect rect centered in a container, i.e. exactly
the contain/letterbox placement. No new function: render paths and the guide
border both call `CropMath.aspectFitRect(sourceSize, in: canvas)`.

### Cursor / click overlays under fit

Cursor and click overlays sit **on the screen content**, which is now letterboxed
into a sub-rect of the canvas. Their placement (`sourcePerPoint`, sample mapping
in `StudioCompositor`) must compose with the same contain transform so the cursor
lands on the screen pixels, not the full canvas.

Text and camera overlays are normalized to the **canvas** (0–1 of `renderSize`),
so they need **no change** — and they can deliberately be placed in the black
bars. That is the intended reels workflow: captions / camera fill the empty bars
above and below a landscape recording.

## 3. Studio-only guide — new `ReelsSafeAreaOverlay.swift`

A SwiftUI overlay, never part of the composition or export.

- Added to the `canvas()` ZStack in `StudioWindow.swift`, **topmost** (after
  `TextCanvasOverlay`).
- `.allowsHitTesting(false)` — purely visual, never intercepts clicks/drags.
- Gated: `cropAspect == .nineBySixteenTemplate && model.templateGuideVisible`.
- Computes the 9:16 content rect with the same `aspectFitRect(model.renderSize,
  in: geo.size)` pattern `TextCanvasOverlay` already uses.

Draws, inside that rect:

- **Canvas border** — stroked outline of the 9:16 content rect (dashed accent
  color), so the reels frame boundary is visible. Studio-only.
- **Safe-zone boxes** — translucent fills at approximate TikTok proportions,
  marking where the platform's real UI covers content:
  - **Top tabs bar** — full width, ~top 8% (Following / For You / search).
  - **Right action column** — right ~15% width, ~45–92% height band
    (avatar / like / comment / bookmark / share).
  - **Bottom caption / nav band** — bottom ~22% height, left ~75% width
    (username / description / bottom nav).

Proportions are constants in the overlay; tuning them is a visual pass, not a
data-model concern.

## 4. Toolbar button + state — `StudioWindow.swift` reframeControls

New ephemeral state on `StudioModel` (not in `EditState`, not exported — same
category as `canvasZoom`):

```swift
@Published var templateGuideVisible = false
```

`setCropAspect` drives it automatically:

```swift
func setCropAspect(_ aspect: CropAspect) {
    cropAspect = aspect
    templateGuideVisible = (aspect == .nineBySixteenTemplate)  // on when picked, off otherwise
    cropCenterX = 0.5; cropCenterY = 0.5; cropZoom = 1.0
    refreshPlayerItemForCanvasChange()
    applyVideoComposition()
    saveEdit()
}
```

Button in the `reframeControls` group, beside the aspect menu:

```swift
Toggle(isOn: Binding(get: { model.templateGuideVisible },
                     set: { model.templateGuideVisible = $0 })) {
    Image(systemName: "rectangle.dashed")
}
.toggleStyle(.button)
.disabled(model.cropAspect != .nineBySixteenTemplate)
.help("Toggle reels safe-area guide")
```

- Default: **off + disabled** (no template aspect selected).
- Template selected: **enabled + on** (set by `setCropAspect`).
- Toggle on → guide shows; toggle off → guide hides. Canvas/letterbox stay
  regardless — the button governs only the guide overlay.

## 5. Edge cases

- **9:16 source + template** → contain = full fill, no bars (image-2 right);
  guide + border still draw over the video. ✓
- **Switch template → plain "9:16"** → cover crop returns, `templateGuideVisible`
  flips false, border + boxes vanish. ✓ (spec requirement)
- **Crop pan/zoom slider** hidden in template mode (`cropPannable == false`).
- **Camera / text** unaffected; **cursor / click** ride the contain transform.

## 6. Testing — `Tests/CaptureStudioTests/`

swift-testing, pure helpers only (UI glue — overlay view, toolbar — untested per
project convention):

- `CropAspect.nineBySixteenTemplate.ratio == 9.0 / 16.0`.
- `isFit` true for `.nineBySixteenTemplate`, false for every other case.
- `canvasSize(shortSide: 1080)` for the template = `1080×1920`.
- `CropMath.aspectFitRect` (already covered by existing tests; add fit-mode cases):
  - `1920×1080` into `1080×1920` → width 1080, height 607.5, centered (bars top
    + bottom).
  - `1080×1920` into `1080×1920` → full canvas, no bars.
- `cropRectInSource` is nil when `cropAspect.isFit`.
- `cropPannable` false for the template, true for other non-`original` aspects.

## Out of scope (YAGNI)

- IG Reels / YT Shorts as distinct templates (Approach B's orthogonal enum). One
  TikTok-shaped guide for now; revisit when a second platform is actually needed.
- Baking the chrome into export.
- Zoom-into-fit (scaling a landscape source up to shrink the bars) — fit shows
  the whole frame; cropping is what plain "9:16" is for.
- Configurable letterbox background (blurred video / custom color) — black only.
