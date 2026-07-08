# Studio Screen Studio–style UI Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Studio editor UI into a Screen Studio–style four-zone shell (app bar · canvas toolbar · stage + category rail/inspector · transport + timeline), relocating every existing control and rendering gaps as disabled placeholders — with no engine, model-logic, or file-format changes.

**Architecture:** Pure SwiftUI view-layer refactor of `Sources/CaptureStudio/Studio/StudioWindow.swift`. Split the 1405-line file into a shell + `Inspector/` panels + transport/timeline files. All bindings continue to point at the existing `StudioModel`; the canvas stage and every timeline-lane view are reused verbatim. Work proceeds behavior-preserving-first (extract, app stays identical), then the layout swap, then contextual panels + placeholders.

**Tech Stack:** Swift 6 toolchain (Command Line Tools only), SwiftUI, AppKit, AVFoundation, swift-testing.

## Global Constraints

Copied verbatim from the spec and project CLAUDE.md — every task implicitly includes these:

- **Command Line Tools only — no Xcode.app.** Do NOT bump `swift-testing` (pinned exact `0.12.0`) or `KeyboardShortcuts` (pinned exact `1.10.0`). Add no new SPM dependencies.
- Target macOS 15+. `LSUIElement` (menu-bar only). Bundle id `dev.wadjakorn.capture-studio` stays stable.
- **No changes to** `CameraCompositor`, `Exporter`, `StudioModel` logic/state, timeline-block models, crop/frame math, event mapping, or the `.capturestudio` format. View layer only.
- **No new backend features.** Gaps render as disabled placeholders only. **No audio-waveform rendering.**
- **The existing 109 tests must stay green, unmodified** (except additive new tests). `swift build` and `swift test` must both pass.
- Commit messages in normal English, end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Never push.** Commit locally only; the user pushes (fast-forward only).

## Standard verification gates

**Execution model:** This repo lives on a Debian box that **cannot build the macOS app**. Subagents dispatched here **produce Swift code only — they do not compile, test, or run anything.** All three gates below are run **by the user on their MacBook** after each task; the user reports pass/fail before the next task is dispatched. A subagent's job is to write correct, complete code and hand back the exact gate commands + visual checklist for the user to execute.

Each task references these by name. A task lists which gates apply plus its own **visual checklist**.

- **[BUILD]** — `swift build` completes with no errors/warnings introduced. Run by the user on the Mac.
- **[TEST]** — `swift test` → all tests pass (109 baseline + any this plan adds). Run by the user on the Mac. Regression guard proving model logic is untouched.
- **[VISUAL]** — user builds and launches the real app on the Mac, opens a recording, and walks the task's checklist:
  ```bash
  scripts/build-app.sh debug
  pkill -x CaptureStudio; open dist/CaptureStudio.app
  # then open any *.capturestudio recording and follow the task checklist
  ```
  This is a macOS-GUI check — run it on the Mac (directly, or via the `/run` skill on a Mac host). It cannot be automated from a Linux shell. Because the project does not unit-test UI glue, [VISUAL] is the primary correctness check for layout tasks; treat its checklist as the task's acceptance criteria.

**Reference screenshots:** the two user-supplied Screen Studio captures and the approved mockup at `.superpowers/brainstorm/*/content/screenstudio-clone.html` (gitignored, on disk).

---

## File Structure

**Created:**
- `Sources/CaptureStudio/Studio/Inspector/RailTab.swift` — tab enum + selection→tab mapping
- `Sources/CaptureStudio/Studio/Inspector/InspectorPlaceholder.swift` — `.comingSoon()` helper
- `Sources/CaptureStudio/Studio/Inspector/InspectorShared.swift` — shared style rows/helpers moved out of `StudioView`
- `Sources/CaptureStudio/Studio/Inspector/FrameInspector.swift`
- `Sources/CaptureStudio/Studio/Inspector/CursorInspector.swift`
- `Sources/CaptureStudio/Studio/Inspector/CameraInspector.swift`
- `Sources/CaptureStudio/Studio/Inspector/CaptionsInspector.swift`
- `Sources/CaptureStudio/Studio/Inspector/AudioInspector.swift`
- `Sources/CaptureStudio/Studio/Inspector/ShortcutsInspector.swift`
- `Sources/CaptureStudio/Studio/Inspector/ShareInspector.swift`
- `Sources/CaptureStudio/Studio/Inspector/ShapeInspector.swift` — contextual (via Mask tool)
- `Sources/CaptureStudio/Studio/Inspector/ZoomInspector.swift` — contextual (via zoom lane)
- `Sources/CaptureStudio/Studio/Inspector/InspectorRail.swift` — the 7-icon rail + panel router
- `Sources/CaptureStudio/Studio/StudioAppBar.swift`
- `Sources/CaptureStudio/Studio/StudioCanvasToolbar.swift`
- `Sources/CaptureStudio/Studio/StudioTransportBar.swift`
- `Tests/CaptureStudioTests/RailTabTests.swift`
- `Tests/CaptureStudioTests/ColorHexTests.swift`

**Modified:**
- `Sources/CaptureStudio/Studio/StudioWindow.swift` — shrinks to `StudioView` shell (zones + stage + load states); everything else moves out.

---

## Task 1: Rail model + placeholder helper (pure logic, TDD)

The one piece with real logic worth unit-testing: which inspector tab a given selection maps to. Build this first, standalone, before any UI wiring.

**Files:**
- Create: `Sources/CaptureStudio/Studio/Inspector/RailTab.swift`
- Create: `Sources/CaptureStudio/Studio/Inspector/InspectorPlaceholder.swift`
- Test: `Tests/CaptureStudioTests/RailTabTests.swift`

**Interfaces:**
- Produces:
  - `enum RailTab: CaseIterable { case frame, cursor, camera, captions, audio, shortcuts, share }`
    with `var symbol: String` (SF Symbol) and `var title: String`.
  - `enum InspectorContext: Equatable { case tab(RailTab); case shape; case zoom }` — what the inspector currently shows (rail tab, or a contextual panel).
  - `struct StudioSelectionSummary { let textSelected, shapeSelected, zoomSelected, cameraMoveSelected, layoutSelected, subtitleSelected: Bool }` — a plain value the view builds from `StudioModel`'s `selected*` flags (keeps this unit pure/testable without importing model UI state).
  - `static func InspectorContext.resolve(selection: StudioSelectionSummary, activeTab: RailTab) -> InspectorContext` — selection wins over the active tab; shape/zoom route to contextual, text/subtitle→captions, cameraMove/layout→camera; nothing selected → `.tab(activeTab)`.
  - `extension View { func comingSoon(_ note: String = "Soon") -> some View }`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CaptureStudioTests/RailTabTests.swift
import Testing
@testable import CaptureStudio

@Suite struct RailTabTests {
    private func sel(text: Bool = false, shape: Bool = false, zoom: Bool = false,
                     cameraMove: Bool = false, layout: Bool = false, subtitle: Bool = false)
    -> StudioSelectionSummary {
        StudioSelectionSummary(textSelected: text, shapeSelected: shape, zoomSelected: zoom,
                               cameraMoveSelected: cameraMove, layoutSelected: layout,
                               subtitleSelected: subtitle)
    }

    @Test func nothingSelectedShowsActiveTab() {
        #expect(InspectorContext.resolve(selection: sel(), activeTab: .audio) == .tab(.audio))
    }
    @Test func shapeSelectionIsContextual() {
        #expect(InspectorContext.resolve(selection: sel(shape: true), activeTab: .frame) == .shape)
    }
    @Test func zoomSelectionIsContextual() {
        #expect(InspectorContext.resolve(selection: sel(zoom: true), activeTab: .frame) == .zoom)
    }
    @Test func textRoutesToCaptions() {
        #expect(InspectorContext.resolve(selection: sel(text: true), activeTab: .frame) == .tab(.captions))
    }
    @Test func subtitleRoutesToCaptions() {
        #expect(InspectorContext.resolve(selection: sel(subtitle: true), activeTab: .frame) == .tab(.captions))
    }
    @Test func cameraMoveRoutesToCamera() {
        #expect(InspectorContext.resolve(selection: sel(cameraMove: true), activeTab: .audio) == .tab(.camera))
    }
    @Test func layoutRoutesToCamera() {
        #expect(InspectorContext.resolve(selection: sel(layout: true), activeTab: .audio) == .tab(.camera))
    }
    @Test func sevenTabsExist() {
        #expect(RailTab.allCases.count == 7)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RailTabTests`
Expected: FAIL — `StudioSelectionSummary` / `InspectorContext` / `RailTab` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/CaptureStudio/Studio/Inspector/RailTab.swift
import SwiftUI

enum RailTab: String, CaseIterable, Hashable {
    case frame, cursor, camera, captions, audio, shortcuts, share

    var symbol: String {
        switch self {
        case .frame:     return "crop"
        case .cursor:    return "cursorarrow"
        case .camera:    return "person.crop.square"
        case .captions:  return "captions.bubble"
        case .audio:     return "speaker.wave.2"
        case .shortcuts: return "command"
        case .share:     return "square.and.arrow.up"
        }
    }
    var title: String {
        switch self {
        case .frame:     return "Frame"
        case .cursor:    return "Cursor"
        case .camera:    return "Camera"
        case .captions:  return "Captions"
        case .audio:     return "Audio"
        case .shortcuts: return "Shortcuts"
        case .share:     return "Share"
        }
    }
}

/// Plain snapshot of the model's selection flags — keeps context resolution
/// pure and unit-testable.
struct StudioSelectionSummary: Equatable {
    var textSelected = false
    var shapeSelected = false
    var zoomSelected = false
    var cameraMoveSelected = false
    var layoutSelected = false
    var subtitleSelected = false
}

/// What the inspector is currently showing.
enum InspectorContext: Equatable {
    case tab(RailTab)
    case shape
    case zoom

    /// Selection wins over the active rail tab. Shape/zoom are contextual;
    /// text/subtitle live under Captions; camera-move/layout under Camera.
    static func resolve(selection s: StudioSelectionSummary,
                        activeTab: RailTab) -> InspectorContext {
        if s.shapeSelected { return .shape }
        if s.zoomSelected { return .zoom }
        if s.textSelected || s.subtitleSelected { return .tab(.captions) }
        if s.cameraMoveSelected || s.layoutSelected { return .tab(.camera) }
        return .tab(activeTab)
    }
}
```

```swift
// Sources/CaptureStudio/Studio/Inspector/InspectorPlaceholder.swift
import SwiftUI

private struct ComingSoonModifier: ViewModifier {
    let note: String
    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            content
            Text(note)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
                .foregroundStyle(.secondary)
        }
        .disabled(true)
        .opacity(0.55)
        .help("Coming soon — not yet available")
    }
}

extension View {
    /// Render a control as a deliberate, disabled placeholder with a "Soon" tag.
    func comingSoon(_ note: String = "Soon") -> some View {
        modifier(ComingSoonModifier(note: note))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RailTabTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Full regression + commit**

Run: `swift build` → [BUILD] clean · `swift test` → [TEST] all pass (117 total).

```bash
git add Sources/CaptureStudio/Studio/Inspector/RailTab.swift \
        Sources/CaptureStudio/Studio/Inspector/InspectorPlaceholder.swift \
        Tests/CaptureStudioTests/RailTabTests.swift
git commit -m "feat(studio): rail-tab model + placeholder helper for UI redesign

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Extract shared inspector helpers (behavior-preserving)

Move the shared style/color/slider helpers and constants out of `StudioView` so every inspector panel can reuse them. No layout change — the app stays byte-identical in behavior. Lock the one pure helper (`Color` hex round-trip) with a test since we're relocating it.

**Files:**
- Create: `Sources/CaptureStudio/Studio/Inspector/InspectorShared.swift`
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` — remove the moved members
- Test: `Tests/CaptureStudioTests/ColorHexTests.swift`

**Interfaces:**
- Produces (all moved verbatim from `StudioWindow.swift`, changed from `private` on `StudioView` to internal free functions / a caller-passed `model`):
  - `struct StylePopoverHeightKey: PreferenceKey` (from `StudioWindow.swift:8-13`)
  - `let inspectorFontFamilies: [String]` (from `fontFamilies`, `:975-978`)
  - `let inspectorBorderPresets: [String]` (from `borderPresets`, `:846-849`)
  - `extension Color { init(hexString:); func hexString() }` (from `:1386-1405`)
  - `func styleSlider(_:value:range:onModel:)`, `func styleSliderText(...)`, `func styleSliderSubtitle(...)`, `func volumeSlider(...)`, `func textColorRow(_:hex:set:)`, `func borderColorControls(model:)` — each takes the `StudioModel` (or the specific closures) it needs, since they no longer live on `StudioView`.
- Consumes: `StudioModel` (existing).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CaptureStudioTests/ColorHexTests.swift
import SwiftUI
import Testing
@testable import CaptureStudio

@Suite struct ColorHexTests {
    @Test func roundTripsPrimaries() {
        #expect(Color(hexString: "#FF0000").hexString() == "#FF0000")
        #expect(Color(hexString: "#00FF00").hexString() == "#00FF00")
        #expect(Color(hexString: "#0000FF").hexString() == "#0000FF")
    }
    @Test func acceptsNoHashAndLowercase() {
        #expect(Color(hexString: "ffffff").hexString() == "#FFFFFF")
    }
    @Test func fallsBackToWhiteOnGarbage() {
        #expect(Color(hexString: "nope").hexString() == "#FFFFFF")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ColorHexTests`
Expected: FAIL to compile or link until the extension is visible to tests (it currently lives in `StudioWindow.swift` and compiles, so tests may pass already; if so, this test still locks behavior before the move — proceed).

- [ ] **Step 3: Create `InspectorShared.swift` and move members**

Move these blocks **verbatim** from `StudioWindow.swift` into the new file, adjusting only ownership:
- `StylePopoverHeightKey` (`:8-13`) → top-level (unchanged).
- `Color` hex extension (`:1386-1405`) → top-level (unchanged).
- `fontFamilies` (`:975-978`) → `let inspectorFontFamilies` (rename references).
- `borderPresets` (`:846-849`) → `let inspectorBorderPresets`.
- `styleSlider` (`:961-969`), `styleSliderText` (`:1072-1080`), `styleSliderSubtitle` (`:1208-1216`), `volumeSlider` (`:820-841`), `textColorRow` (`:1248-1270`), `borderColorControls` (`:935-959`): convert from `StudioView` methods to free functions that take the values/closures they need (they already reference `model.*`; pass `model: StudioModel`). Show the converted signature for each, e.g.:

```swift
// InspectorShared.swift (representative — repeat the pattern for each helper)
func styleSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                 model: StudioModel) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Slider(value: value, in: range) { editing in
            if editing { model.beginStyleEdit() } else { model.endStyleEdit() }
        }
    }
}
```

Update the call sites still in `StudioWindow.swift` to call the free functions (add `model: model`). Rename `fontFamilies`→`inspectorFontFamilies`, `borderPresets`→`inspectorBorderPresets`, `Self.borderPresets`→`inspectorBorderPresets` at all references.

- [ ] **Step 4: Run tests + build**

Run: `swift build` → [BUILD] clean. `swift test --filter ColorHexTests` → PASS. `swift test` → [TEST] all pass.

- [ ] **Step 5: [VISUAL] — app is identical**

Checklist (open a recording with camera + a text block + subtitles):
- Every style popover (camera, text, shape, subtitle, zoom) opens and all sliders/color swatches work exactly as before.
- No visual change anywhere. This task must be invisible to the user.

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/Studio/Inspector/InspectorShared.swift \
        Sources/CaptureStudio/Studio/StudioWindow.swift \
        Tests/CaptureStudioTests/ColorHexTests.swift
git commit -m "refactor(studio): extract shared inspector helpers (no behavior change)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Extract style panels into per-tab inspector views (behavior-preserving)

Move the five style-popover bodies into their own inspector view files. Still invoked by the existing popovers/bottom bar — app stays identical. This isolates each panel so the layout swap (Task 5) just re-parents them.

**Files:**
- Create: `CameraInspector.swift`, `CaptionsInspector.swift`, `ShapeInspector.swift`, `ZoomInspector.swift`, `AudioInspector.swift` (all under `Studio/Inspector/`)
- Modify: `StudioWindow.swift` — replace the popover bodies with calls to the new views

**Interfaces:**
- Produces (each a `struct …Inspector: View` taking `@ObservedObject var model: StudioModel`, body = the moved content):
  - `CameraInspector` ← `cameraStylePopover` (`:851-931`) + `borderColorControls` usage
  - `CaptionsInspector` ← `textStylePopover` (`:980-1070`) **and** `subtitleStylePopover` (`:1084-1206`) as two sub-sections `CaptionsInspector.TextSection` / `.SubtitleSection` (keep them separate structs in one file), plus `textSizeRow` (`:1221-1245`)
  - `ShapeInspector` ← `shapeStylePopover` (`:598-664`)
  - `ZoomInspector` ← `zoomStylePopover` (`:695-746`)
  - `AudioInspector` ← `audioControls` (`:274-287`)
- Consumes: `InspectorShared` helpers (Task 2), `StudioModel`.

- [ ] **Step 1: Create the five inspector view files**

For each, create `struct <Name>Inspector: View { @ObservedObject var model: StudioModel; var body: some View { <moved content> } }`. Move the body **verbatim** from the cited line range, swapping helper calls to the Task 2 free functions (`styleSlider(..., model: model)` etc.) and popover-height state to a `@State` local where it was on `StudioView` (each popover keeps its own height state inside its inspector). Representative skeleton:

```swift
// Sources/CaptureStudio/Studio/Inspector/CameraInspector.swift
import SwiftUI

struct CameraInspector: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        // ← contents of cameraStylePopover (:852-930), with
        //   borderColorControls(model: model) and styleSlider(..., model: model)
    }
}
```

Do the same for `CaptionsInspector` (two sections), `ShapeInspector`, `ZoomInspector`, `AudioInspector`.

- [ ] **Step 2: Rewire `StudioWindow.swift` to call them**

Replace each popover body / control group in `StudioView` with the new view:
- `.popover(...) { cameraStylePopover }` → `.popover(...) { CameraInspector(model: model) }`
- text popover → `CaptionsInspector.TextSection(model: model)`
- subtitle popover → `CaptionsInspector.SubtitleSection(model: model)`
- shape popover → `ShapeInspector(model: model)`
- zoom popover → `ZoomInspector(model: model)`
- `toolGroup { audioControls }` → `toolGroup { AudioInspector(model: model) }`

Delete the now-dead private computed properties (`cameraStylePopover`, `textStylePopover`, `subtitleStylePopover`, `shapeStylePopover`, `zoomStylePopover`, `audioControls`, `textSizeRow`, `borderColorControls`, and the three `@State … PopoverHeight` on `StudioView` if fully moved).

- [ ] **Step 3: Build + tests**

Run: `swift build` → [BUILD] clean. `swift test` → [TEST] all pass.

- [ ] **Step 4: [VISUAL] — still identical**

Checklist: open every style popover and the audio group; confirm all controls present and functional, popover heights still fit, no clipping. Zero visible change intended.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/Inspector/ Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "refactor(studio): extract style panels into per-tab inspector views

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: Build the remaining inspector panels + zone chrome (not yet swapped in)

Create the panels/zones that don't exist yet as standalone views, wiring to existing model members. They compile and could be previewed but aren't in the layout until Task 5. This keeps Task 5 a pure re-parenting.

**Files:**
- Create: `FrameInspector.swift`, `CursorInspector.swift`, `ShortcutsInspector.swift`, `ShareInspector.swift`, `InspectorRail.swift`, `StudioAppBar.swift`, `StudioCanvasToolbar.swift`, `StudioTransportBar.swift`

**Interfaces:**
- Produces:
  - `FrameInspector(model:)` ← relocate `reframeControls` (`:289-364`) + `backgroundControls` (`:368-412`) content, arranged as inspector sections; add a `comingSoon()` "Wallpaper / gradient" placeholder row.
  - `CursorInspector(model:)` ← relocate `cursorControls` (`:804-818`); add `comingSoon()` rows for Size, Smoothing, Click style.
  - `ShortcutsInspector()` — entirely placeholder: a key-overlay preview mock + an enable toggle, all `comingSoon()`.
  - `ShareInspector(model:)` ← reveal-masters button (`:266-272`) + export menu (`exportControls`, `:1327-1361`); add `comingSoon()` "Share / upload" row.
  - `InspectorRail(active: Binding<RailTab>, context: InspectorContext, model:)` — vertical 7-icon rail (uses `RailTab.allCases`, `.symbol`) + a `panel` view that switches on `context`: `.tab(.frame)→FrameInspector`, `.cursor→CursorInspector`, `.camera→CameraInspector`, `.captions→CaptionsInspector` (both sections stacked), `.audio→AudioInspector`, `.shortcuts→ShortcutsInspector`, `.share→ShareInspector`, `.shape→ShapeInspector`, `.zoom→ZoomInspector`.
  - `StudioAppBar(model:)` — filename (`model.bundle` name), `comingSoon()` undo/redo, `comingSoon()` Presets, `comingSoon()` preview/speed, and the real Export control (reuse `exportControls`; keep Stop reachable during export).
  - `StudioCanvasToolbar(model:, activeTab: Binding<RailTab>, maskAction:)` — centered `Auto ▾` (layout menu, drives `.camera` tab), `Crop` (drives `.frame` tab), `Mask` (calls `maskAction` → add shape). Reuse `layoutBinding`/`reframeControls` entry points as needed.
  - `StudioTransportBar(model:)` — relocate `transportControls` (`:241-251`) + `trimControls` (`:253-264`) + a `1×` label placeholder + timelines-visible label.

- [ ] **Step 1: Write each view**

Give each its real content. Representative — the rail router (full code; the rest follow the same "move existing control group into a titled inspector `VStack`" pattern):

```swift
// Sources/CaptureStudio/Studio/Inspector/InspectorRail.swift
import SwiftUI

struct InspectorRail: View {
    @Binding var active: RailTab
    let context: InspectorContext
    @ObservedObject var model: StudioModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(RailTab.allCases, id: \.self) { tab in
                    Button { active = tab } label: {
                        Image(systemName: tab.symbol)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .background(railHighlight(tab), in: RoundedRectangle(cornerRadius: 8))
                    .help(tab.title)
                }
                Spacer()
            }
            .frame(width: 46)
            .padding(.vertical, 10)

            Divider()

            ScrollView { panel.padding(14) }
                .frame(width: 270)
        }
    }

    private func railHighlight(_ tab: RailTab) -> Color {
        if case .tab(let t) = context, t == tab { return .secondary.opacity(0.2) }
        return .clear
    }

    @ViewBuilder private var panel: some View {
        switch context {
        case .shape: ShapeInspector(model: model)
        case .zoom:  ZoomInspector(model: model)
        case .tab(let t):
            switch t {
            case .frame:     FrameInspector(model: model)
            case .cursor:    CursorInspector(model: model)
            case .camera:    CameraInspector(model: model)
            case .captions:  CaptionsInspector(model: model)   // stacks Text + Subtitle sections
            case .audio:     AudioInspector(model: model)
            case .shortcuts: ShortcutsInspector()
            case .share:     ShareInspector(model: model)
            }
        }
    }
}
```

For `FrameInspector`/`CursorInspector`/`ShareInspector`/`StudioAppBar`/`StudioCanvasToolbar`/`StudioTransportBar`/`ShortcutsInspector`: move the cited existing control groups into a titled section layout, and add the `comingSoon()` placeholder rows named in the Interfaces block. Each placeholder is e.g.:

```swift
Toggle("Improve microphone audio", isOn: .constant(false)).comingSoon()
```

- [ ] **Step 2: Build (views compile, unused is fine)**

Run: `swift build` → [BUILD] clean. Swift will warn on unused views only if referenced nowhere; suppress by keeping them `internal` (SPM won't warn on unused internal types). `swift test` → [TEST] all pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/CaptureStudio/Studio/
git commit -m "feat(studio): add rail, zone chrome, and remaining inspector panels

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Swap `editorView` to the four-zone layout

Re-parent everything into the Screen Studio shell. This is the visible change. The canvas stage (`canvas(player:)`, `:85-139`) and every timeline lane view are reused verbatim.

**Files:**
- Modify: `StudioWindow.swift` — rewrite `editorView`; delete the old `controlBar`, `toolGroup`, and the relocated control groups; add rail state.

**Interfaces:**
- Consumes: all of Tasks 1–4.
- Produces: new `editorView` composition; `@State private var activeTab: RailTab = .frame`; `@State private var inspectorContext` derived each body from `InspectorContext.resolve(...)`.

- [ ] **Step 1: Add selection→context wiring**

```swift
// in StudioView
@State private var activeTab: RailTab = .frame

private var selectionSummary: StudioSelectionSummary {
    StudioSelectionSummary(
        textSelected: model.selectedTextBlockID != nil,
        shapeSelected: model.selectedShapeBlockID != nil,
        zoomSelected: model.selectedZoomBlockID != nil,
        cameraMoveSelected: model.selectedBlockID != nil,
        layoutSelected: model.selectedLayoutBlockID != nil,
        subtitleSelected: model.subtitleSelected)
}
private var inspectorContext: InspectorContext {
    InspectorContext.resolve(selection: selectionSummary, activeTab: activeTab)
}
```

(Confirm each `model.selected*` name against `StudioModel` while wiring; adjust to the actual property names if they differ — do not change the model.)

- [ ] **Step 2: Rewrite `editorView`**

```swift
private var editorView: some View {
    VStack(spacing: 0) {
        StudioAppBar(model: model)
        Divider()
        StudioCanvasToolbar(model: model, activeTab: $activeTab,
                            maskAction: { model.addShapeBlock(kind: .rectangle) })
        Divider()
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let player = model.player {
                    canvas(player: player).disabled(model.isExporting)
                }
            }
            Divider()
            InspectorRail(active: $activeTab, context: inspectorContext, model: model)
                .disabled(model.isExporting)
        }
        Divider()
        StudioTransportBar(model: model).disabled(model.isExporting)
        timelineStack.disabled(model.isExporting)   // the existing lane rows, extracted
    }
    .background { /* keep the existing deselect / Esc / close-guard background block :64-79 */ }
}
```

Extract the existing lane rows (`:165-185`) into a `timelineStack` computed property (verbatim `laneRow(...)` calls). Delete `controlBar`, `toolGroup`, and the old inline control groups now living in inspectors.

- [ ] **Step 3: Build + tests**

Run: `swift build` → [BUILD] clean. `swift test` → [TEST] all pass.

- [ ] **Step 4: [VISUAL] — the new shell works**

Checklist (open a recording with camera, a text block, a shape, subtitles, a zoom block):
- Four zones render top-to-bottom: app bar · canvas toolbar · (stage | rail+inspector) · transport · timeline.
- Clicking each of the 7 rail icons shows the right panel; every relocated control works and mutates the preview (aspect, background, camera style, cursor toggles, audio, export).
- Transport play/pause + timecode + trim work; Export runs and Stop is reachable during export.
- Timeline lanes still render and scrub.
- Nothing from the old bottom bar is missing — cross-check against the migration checklist in the spec.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "feat(studio): swap editor to Screen Studio four-zone layout

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: Contextual panels — Mask tool, zoom lane, selection auto-switch

Wire the two contextual entry points and confirm selection flips the inspector.

**Files:**
- Modify: `StudioCanvasToolbar.swift` (Mask add menu), `StudioWindow.swift` (zoom-lane add affordance styling hook), `InspectorRail.swift` (already routes `.shape`/`.zoom`).

**Interfaces:**
- Consumes: `InspectorContext.resolve` (Task 1), `ShapeInspector`/`ZoomInspector` (Task 3), rail router (Task 4).

- [ ] **Step 1: Mask add menu**

Replace the single `maskAction` with a Menu in `StudioCanvasToolbar`:

```swift
Menu {
    Button("Rectangle") { model.addShapeBlock(kind: .rectangle) }
    Button("Ellipse")   { model.addShapeBlock(kind: .ellipse) }
    Button("Blur (censor)") { model.addShapeBlock(kind: .blur) }
} label: { Label("Mask", systemImage: "circle.dashed.rectangle") }
```

Adding a shape sets `selectedShapeBlockID` (existing behavior), so `inspectorContext` resolves to `.shape` and the Shape panel appears — no extra wiring.

- [ ] **Step 2: Zoom-lane entry**

The existing `ZoomTimelineLane` selects a zoom block on click (existing behavior → `selectedZoomBlockID`), which resolves to `.zoom`. Confirm the lane is present in `timelineStack` and that selecting a zoom block shows `ZoomInspector`. No model change; if an explicit "add zoom" affordance is wanted on the lane, keep the existing `model.addZoomBlock()` button — relocate it into the transport bar's zoom control or leave in the lane as today.

- [ ] **Step 3: Build + tests**

Run: `swift build` → [BUILD] clean. `swift test` → [TEST] all pass (the resolve logic is already covered by RailTabTests).

- [ ] **Step 4: [VISUAL] — contextual panels**

Checklist:
- `Mask ▾` → each of rectangle/ellipse/blur adds a shape and the inspector immediately shows the **Shape** panel with that shape's props; editing works; deselect returns to the previously active tab.
- Select a zoom block on the zoom lane → inspector shows the **Zoom** panel (scale/sensitivity/overflow); deselect returns.
- Selecting a text block shows Captions; a camera-move shows Camera. Rail highlight follows.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/
git commit -m "feat(studio): Mask tool + zoom-lane contextual inspector panels

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: Dark restyle + export-lock re-verification + polish

Restyle the shell toward the Screen Studio look (dark zones, thicker timeline lanes, styled zoom lane), and re-verify the export lock across all new zones. No new controls.

**Files:**
- Modify: zone views (`StudioAppBar`, `StudioCanvasToolbar`, `InspectorRail`, `StudioTransportBar`, `StudioWindow` timeline), applying consistent backgrounds/spacing. Restyle the main scrubber (`timeline`, `:1287-1318`) thicker (raise the 6px bar and 2px playhead to ~10px/3px).

**Interfaces:** none new.

- [ ] **Step 1: Apply styling**

Use `.background(.bar)` / material backgrounds per zone, consistent 12pt padding, and a `.thickMaterial` inspector column to echo the reference. Thicken the scrubber and lane rows. Keep it tasteful — this is polish, not new structure. (Frontend-design judgment applies; match the approved mockup's proportions.)

- [ ] **Step 2: Re-verify export lock**

Confirm `.disabled(model.isExporting)` is applied to: canvas, rail+inspector, canvas toolbar, transport, timeline — but NOT the app-bar Export/Stop group. Confirm `StudioWindowCloseGuard` still blocks close during export.

- [ ] **Step 3: Build + full regression**

Run: `swift build` → [BUILD] clean. `swift test` → [TEST] all 117 pass.

- [ ] **Step 4: [VISUAL] — final pass**

Checklist:
- Overall look reads like the reference mockup (dark, three-zone, right rail).
- Start an export: the whole editor locks (rail, toolbar, transport, timeline all inert), the Stop button works and cancels, window won't close mid-export; on completion the editor unlocks.
- Resize the window narrow→wide: zones hold their positions (no chaotic reflow like the old FlowLayout).
- Spot-check the full spec migration checklist one final time — every old control is present and functional.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/
git commit -m "feat(studio): dark restyle, thicker timeline, export-lock across new zones

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** Four zones → Tasks 4–5. Seven rail tabs → Tasks 3–4. Frame/Cursor/Camera/Captions/Audio/Shortcuts/Share panels → Tasks 3–4. Shapes via Mask + Zoom via lane (contextual) → Tasks 1,3,6. Selection↔category coexistence → Task 1 (tested) + Task 5 (wired). Placeholder pattern + inventory → Task 1 helper + Task 4 rows. File split → Tasks 2–5. Export lock → Tasks 5,7. Waveform skipped → honored (Task 7 restyles the lane only). Every migration-checklist row maps to a task (Tasks 3–6). No gaps found.

**Placeholder scan:** No "TBD/TODO" left as deliverables. Extraction steps cite exact source line ranges to move rather than re-pasting 1400 lines verbatim — this is a deliberate choice for behavior-preserving moves (re-pasting risks divergence from the source of truth); all *new* code is given in full.

**Type consistency:** `RailTab`, `InspectorContext`, `StudioSelectionSummary`, `InspectorContext.resolve`, `.comingSoon()`, `inspectorFontFamilies`, `inspectorBorderPresets`, and each `<Name>Inspector(model:)` are used consistently across Tasks 1–7. `model.selected*` property names are flagged in Task 5 Step 1 to verify against the real `StudioModel` at wiring time (the model is not modified).

**Known risk carried forward:** [VISUAL] gates require a macOS host; they cannot run from this Linux dev box. The executor must run them on a Mac (or via `/run` on a Mac host). This is the primary correctness check for the layout tasks and must not be skipped.
