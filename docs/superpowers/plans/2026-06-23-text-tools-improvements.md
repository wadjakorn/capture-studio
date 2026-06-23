# Text Tools Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Studio text/caption authoring faster and finer-grained: inherit last-edited style, smaller fonts shown in px, a resizable wrap box with an auto-wrap toggle, and selection-driven inline editing.

**Architecture:** Two new persisted `TextBlock` fields (`boxWidth`, `autoWrap`) drive Core Text wrapping in `TextImageRenderer`. `StudioModel` keeps an in-memory `lastTextStyle` template so new blocks clone the last edit, and its text-editing state collapses to selection-driven (no separate `editingTextBlockID`). The caption text input moves from a timeline popover / canvas double-click into an inline field in the text tool group; the canvas overlay gains width resize handles.

**Tech Stack:** Swift 6 (Command Line Tools toolchain only — no Xcode.app), SwiftUI, Core Text / Core Graphics, swift-testing.

## Global Constraints

- Toolchain: **Command Line Tools only.** Do NOT bump swift-testing (pinned `0.12.0`) or KeyboardShortcuts (pinned `1.10.0`).
- Build with `swift build`; test with `swift test`. Keep all existing tests green (109 today).
- `TextBlock` schema stays backward-compatible via the existing `init(from:)` + `decodeIfPresent` pattern. `EditState.schemaVersion` stays `1`.
- `fontSize` is a fraction of canvas **height**; `boxWidth` is a fraction of canvas **width**. Both keep blocks identical at preview and export resolution.
- Commit messages in normal English, end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Never commit without explicit user confirmation** (project rule). Commit steps below are the intended boundaries; pause for confirmation before actually committing.

## File map

- `Sources/CaptureStudio/ProjectBundle/EditState.swift` — add `boxWidth`, `autoWrap` to `TextBlock`.
- `Sources/CaptureStudio/Studio/TextImageRenderer.swift` — wrap to `boxWidth` / honor `autoWrap`.
- `Sources/CaptureStudio/Studio/StudioModel.swift` — `lastTextStyle` inheritance, `setTextBoxWidth`/`setTextAutoWrap`, lowered font clamp, collapse editing state.
- `Sources/CaptureStudio/Studio/TextCanvasOverlay.swift` — wrap-frame box + resize handles, drop double-click edit.
- `Sources/CaptureStudio/Studio/TextTimelineLane.swift` — block tap selects (no longer opens editor).
- `Sources/CaptureStudio/Studio/StudioWindow.swift` — inline caption field in the tool group, px Size row, auto-wrap + box-width controls, remove popover editor, fix Esc gating.
- `Tests/CaptureStudioTests/EditStateTests.swift` — new-field round-trip + missing-field defaults.
- `Tests/CaptureStudioTests/TextImageRendererTests.swift` (new) — wrap/auto-wrap measurement.
- `Tests/CaptureStudioTests/TextTimelineTests.swift` — `add` copies template style.

---

### Task 1: Add `boxWidth` + `autoWrap` to `TextBlock`

**Files:**
- Modify: `Sources/CaptureStudio/ProjectBundle/EditState.swift:156-239`
- Test: `Tests/CaptureStudioTests/EditStateTests.swift`

**Interfaces:**
- Produces: `TextBlock.boxWidth: Double` (default `0.9`), `TextBlock.autoWrap: Bool` (default `true`). Both decode to their defaults when absent from a bundle.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CaptureStudioTests/EditStateTests.swift` (inside `@Suite struct EditStateTests`):

```swift
@Test func textBlockNewFieldsRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let bundle = try ProjectBundle.createNew(in: dir)
    defer { try? FileManager.default.removeItem(at: dir) }

    var tb = TextBlock(begin: 0, end: 2, text: "hi")
    tb.boxWidth = 0.42
    tb.autoWrap = false
    var edit = EditState()
    edit.textBlocks = [tb]
    try bundle.writeEdit(edit)

    let loaded = bundle.loadEdit().textBlocks.first
    #expect(loaded?.boxWidth == 0.42)
    #expect(loaded?.autoWrap == false)
}

@Test func textBlockMissingNewFieldsDefault() throws {
    let id = UUID().uuidString
    let json = """
    {"id":"\(id)","begin":0,"end":2,"text":"hi","centerX":0.5,"centerY":0.85,\
    "fontName":"Helvetica","fontSize":0.06,"fontWeight":"semibold","colorHex":"#FFFFFF",\
    "alignment":"center","boxEnabled":false,"boxHex":"#000000","boxOpacity":0.5,\
    "strokeWidth":0,"strokeHex":"#000000","shadow":true,"source":"manual"}
    """.data(using: .utf8)!
    let tb = try JSONDecoder().decode(TextBlock.self, from: json)
    #expect(tb.boxWidth == 0.9)
    #expect(tb.autoWrap == true)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EditStateTests`
Expected: FAIL — `value of type 'TextBlock' has no member 'boxWidth'` (compile error).

- [ ] **Step 3: Add the two stored fields**

In `EditState.swift`, in `struct TextBlock`, immediately after `var shadow: Bool` (line 174) and before the `// Forward-compat:` comment, insert:

```swift
    /// Wrap-frame width as a fraction of canvas width. Text soft-wraps to this
    /// width when `autoWrap` is on; ignored when off. 0.9 reproduces the legacy
    /// hardcoded wrap width.
    var boxWidth: Double
    /// When true, text soft-wraps to `boxWidth`; when false only explicit
    /// newlines break lines (long lines extend past the canvas edges).
    var autoWrap: Bool
```

- [ ] **Step 4: Add `init` parameters + assignments**

Change the memberwise `init` signature. Replace:

```swift
         strokeWidth: Double = 0, strokeHex: String = "#000000",
         shadow: Bool = true, source: TextSource = .manual) {
```

with:

```swift
         strokeWidth: Double = 0, strokeHex: String = "#000000",
         shadow: Bool = true, boxWidth: Double = 0.9, autoWrap: Bool = true,
         source: TextSource = .manual) {
```

And immediately after `self.shadow = shadow` (line 202) insert:

```swift
        self.boxWidth = boxWidth
        self.autoWrap = autoWrap
```

- [ ] **Step 5: Add `decodeIfPresent` lines**

In `init(from decoder:)`, immediately after the `shadow = ...` line (line 235) and before `let sourceRaw = ...`, insert:

```swift
        boxWidth = try c.decodeIfPresent(Double.self, forKey: .boxWidth) ?? 0.9
        autoWrap = try c.decodeIfPresent(Bool.self, forKey: .autoWrap) ?? true
```

(`CodingKeys` is compiler-synthesized from the stored properties, so `.boxWidth` / `.autoWrap` exist automatically.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter EditStateTests`
Expected: PASS (all EditStateTests, including the two new ones).

- [ ] **Step 7: Commit**

```bash
git add Sources/CaptureStudio/ProjectBundle/EditState.swift Tests/CaptureStudioTests/EditStateTests.swift
git commit -m "feat: add boxWidth and autoWrap to TextBlock

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Wrap to `boxWidth` and honor `autoWrap` in the renderer

**Files:**
- Modify: `Sources/CaptureStudio/Studio/TextImageRenderer.swift:97`
- Test: `Tests/CaptureStudioTests/TextImageRendererTests.swift` (new)

**Interfaces:**
- Consumes: `TextBlock.boxWidth`, `TextBlock.autoWrap` (Task 1).
- Produces: `TextImageRenderer.size(_:canvas:)` height grows as `boxWidth` shrinks (when `autoWrap`); with `autoWrap == false` the text measures as a single line (no soft wrap).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CaptureStudioTests/TextImageRendererTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import CaptureStudio

@Suite struct TextImageRendererTests {
    private let canvas = CGSize(width: 1000, height: 1000)
    private let sentence = "the quick brown fox jumps over the lazy dog again"

    private func block(boxWidth: Double, autoWrap: Bool) -> TextBlock {
        var b = TextBlock(begin: 0, end: 1, text: sentence)
        b.fontSize = 0.05
        b.boxWidth = boxWidth
        b.autoWrap = autoWrap
        return b
    }

    @Test func narrowerBoxWrapsTaller() {
        let wide = TextImageRenderer.size(block(boxWidth: 0.9, autoWrap: true), canvas: canvas)
        let narrow = TextImageRenderer.size(block(boxWidth: 0.3, autoWrap: true), canvas: canvas)
        #expect(narrow.height > wide.height)
        #expect(narrow.width < wide.width)
    }

    @Test func autoWrapOffStaysSingleLine() {
        let wrapped = TextImageRenderer.size(block(boxWidth: 0.3, autoWrap: true), canvas: canvas)
        let noWrap = TextImageRenderer.size(block(boxWidth: 0.3, autoWrap: false), canvas: canvas)
        #expect(noWrap.height < wrapped.height)   // single line is shorter
        #expect(noWrap.width > wrapped.width)      // and extends wider
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TextImageRendererTests`
Expected: FAIL — `narrow.height > wide.height` is false (wrap width still hardcoded to `canvas.width * 0.9`, so both measure identically), and the auto-wrap-off case wraps too.

- [ ] **Step 3: Use `boxWidth` / `autoWrap` for the wrap constraint**

In `TextImageRenderer.swift`, replace line 97:

```swift
        let maxWidth = canvas.width * 0.9
```

with:

```swift
        let maxWidth: CGFloat = block.autoWrap
            ? max(1, canvas.width * CGFloat(block.boxWidth))
            : .greatestFiniteMagnitude
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TextImageRendererTests`
Expected: PASS (both tests).

- [ ] **Step 5: Run the full suite to confirm no regressions**

Run: `swift test`
Expected: PASS (all tests; existing blocks default `boxWidth = 0.9`, reproducing prior wrapping).

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/Studio/TextImageRenderer.swift Tests/CaptureStudioTests/TextImageRendererTests.swift
git commit -m "feat: wrap caption text to boxWidth and honor autoWrap

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Model — style inheritance, box/wrap setters, lower font clamp

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift:712-719, 767-771, 804-809, 906, 915`
- Test: `Tests/CaptureStudioTests/TextTimelineTests.swift`

**Interfaces:**
- Consumes: `TextBlock.boxWidth`, `TextBlock.autoWrap` (Task 1); `TextTimeline.add(_:atTime:width:duration:template:)` (existing).
- Produces:
  - `StudioModel.setTextBoxWidth(_ v: Double)` — clamps to `0.05...1.0`, live (commit on end).
  - `StudioModel.setTextAutoWrap(_ on: Bool)` — discrete commit.
  - `StudioModel.addTextBlock()` now clones the in-memory `lastTextStyle` (style + position + `boxWidth` + `autoWrap`) with empty text.
  - Font-size hard clamp lowered to `0.005...0.5`.

- [ ] **Step 1: Write the failing test (template inheritance is pure in `TextTimeline.add`)**

Add to `Tests/CaptureStudioTests/TextTimelineTests.swift` (inside its `@Suite`):

```swift
@Test func addCopiesTemplateStyleAndResetsSpan() {
    var template = TextBlock(begin: 0, end: 0)
    template.fontSize = 0.09
    template.colorHex = "#FF0000"
    template.boxWidth = 0.4
    template.autoWrap = false
    template.centerX = 0.3
    template.centerY = 0.2

    let (blocks, id) = TextTimeline.add([], atTime: 2, width: 3,
                                        duration: 10, template: template)
    let b = blocks.first { $0.id == id }!
    #expect(b.fontSize == 0.09)
    #expect(b.colorHex == "#FF0000")
    #expect(b.boxWidth == 0.4)
    #expect(b.autoWrap == false)
    #expect(b.centerX == 0.3)
    #expect(b.centerY == 0.2)
    #expect(b.begin == 2)
    #expect(b.end == 5)
    #expect(b.id != template.id)
    #expect(b.text == "")
}
```

- [ ] **Step 2: Run test to verify it passes-or-fails**

Run: `swift test --filter TextTimelineTests`
Expected: PASS already for the style/span assertions (TextTimeline.add copies the template and overrides id/begin/end). This test locks in the contract that Task 3's `addTextBlock` relies on. If it FAILS to compile (`boxWidth`/`autoWrap` missing), Task 1 was not applied — stop and fix.

- [ ] **Step 3: Add the `lastTextStyle` template property**

In `StudioModel.swift`, immediately after the `static let defaultTextWidth = 3.0` line (line 60), add:

```swift
    /// Style/position template for the next added text block — every block edit
    /// snapshots into it so a new block clones the most recent one (text aside).
    /// In-memory only: resets each launch (no cross-session memory).
    private var lastTextStyle = TextBlock(begin: 0, end: 0)
```

- [ ] **Step 4: Snapshot the template on every block mutation**

Replace `updateTextBlock` (lines 767-771):

```swift
    private func updateTextBlock(_ id: UUID, _ mutate: (inout TextBlock) -> Void) {
        guard let i = textBlocks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&textBlocks[i])
        applyVideoComposition()
    }
```

with:

```swift
    private func updateTextBlock(_ id: UUID, _ mutate: (inout TextBlock) -> Void) {
        guard let i = textBlocks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&textBlocks[i])
        lastTextStyle = textBlocks[i]   // template tracks the last-edited block
        applyVideoComposition()
    }
```

Canvas position drags bypass `updateTextBlock`, so also capture on drop. Replace `endDraggingText` (lines 804-809):

```swift
    func endDraggingText() {
        guard draggingTextBlockID != nil else { return }
        draggingTextBlockID = nil
        applyVideoComposition()
        saveEdit()
    }
```

with:

```swift
    func endDraggingText() {
        guard let id = draggingTextBlockID else { return }
        draggingTextBlockID = nil
        if let b = textBlocks.first(where: { $0.id == id }) { lastTextStyle = b }
        applyVideoComposition()
        saveEdit()
    }
```

- [ ] **Step 5: Clone the template in `addTextBlock`**

Replace `addTextBlock` (lines 712-719):

```swift
    func addTextBlock() {
        let t = min(max(currentTime, 0), duration)
        let added = TextTimeline.add(textBlocks, atTime: t, width: Self.defaultTextWidth,
                                     duration: duration,
                                     template: TextBlock(begin: 0, end: 0))
        setTextBlocks(added.blocks, select: added.id)
        editingTextBlockID = added.id
    }
```

with:

```swift
    func addTextBlock() {
        let t = min(max(currentTime, 0), duration)
        var template = lastTextStyle
        template.text = ""              // inherit style + position, never the words
        let added = TextTimeline.add(textBlocks, atTime: t, width: Self.defaultTextWidth,
                                     duration: duration, template: template)
        setTextBlocks(added.blocks, select: added.id)
        editingTextBlockID = added.id   // (removed in Task 5)
    }
```

- [ ] **Step 6: Lower the font-size clamp**

Replace line 906:

```swift
    func setTextFontSize(_ v: Double) { updateSelectedText(commit: false) { $0.fontSize = min(max(0.01, v), 0.5) } }
```

with:

```swift
    func setTextFontSize(_ v: Double) { updateSelectedText(commit: false) { $0.fontSize = min(max(0.005, v), 0.5) } }
```

- [ ] **Step 7: Add the box-width and auto-wrap setters**

Immediately after `setTextShadow` (line 915), add:

```swift
    func setTextBoxWidth(_ v: Double) { updateSelectedText(commit: false) { $0.boxWidth = min(max(0.05, v), 1.0) } }
    func setTextAutoWrap(_ on: Bool) { updateSelectedText(commit: true) { $0.autoWrap = on } }
```

- [ ] **Step 8: Build + run tests**

Run: `swift build && swift test --filter TextTimelineTests`
Expected: build succeeds; TextTimelineTests PASS. (`editingTextBlockID` still exists, so the model compiles.)

- [ ] **Step 9: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift Tests/CaptureStudioTests/TextTimelineTests.swift
git commit -m "feat: new text inherits last-edited style; add box-width/wrap setters; lower font min

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Canvas wrap-frame box + width resize handles

**Files:**
- Modify: `Sources/CaptureStudio/Studio/TextCanvasOverlay.swift:25-44, 68-87`

**Interfaces:**
- Consumes: `model.setTextBoxWidth(_:)`, `model.commitTextEdit()` (Task 3); `TextBlock.boxWidth`, `TextBlock.autoWrap`.
- Produces: a selection box sized to the wrap frame (when `autoWrap`) with left/right drag handles that change `boxWidth` symmetrically about the center.

This task is UI glue (not unit-tested per project convention). Deliverable: `swift build` succeeds and the described behavior is present.

- [ ] **Step 1: Add resize-drag state**

In `TextCanvasOverlay`, after the existing `@State private var dragStart: CGPoint?` (line 14), add:

```swift
    @State private var resizeStartWidth: Double?
```

- [ ] **Step 2: Size the box from the wrap frame and add handles**

Replace the selected-block block (lines 25-44):

```swift
                if let block = activeSelectedBlock, model.renderSize.width > 0 {
                    let videoRect = aspectFitRect(model.renderSize, in: geo.size)
                    let viewScale = videoRect.width / model.renderSize.width
                    let cx = videoRect.minX + CGFloat(block.centerX) * model.renderSize.width * viewScale
                    let cy = videoRect.minY + CGFloat(block.centerY) * model.renderSize.height * viewScale
                    let measured = TextImageRenderer.size(block, canvas: model.renderSize)
                    let boxW = max(measured.width * viewScale, 44)
                    let boxH = max(measured.height * viewScale, 26)

                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .contentShape(Rectangle())            // whole box is draggable
                        .frame(width: boxW, height: boxH)
                        .gesture(moveGesture(block: block, viewScale: viewScale))
                        .onTapGesture(count: 2) { model.beginEditingText(block.id) }
                        // Consume single taps so a click on the box keeps the
                        // selection instead of falling through to the catcher.
                        .onTapGesture { model.selectTextBlock(block.id) }
                        .help("Drag to move · double-click to edit text")
                        .position(x: cx, y: cy)
                }
```

with:

```swift
                if let block = activeSelectedBlock, model.renderSize.width > 0 {
                    let videoRect = aspectFitRect(model.renderSize, in: geo.size)
                    let viewScale = videoRect.width / model.renderSize.width
                    let cx = videoRect.minX + CGFloat(block.centerX) * model.renderSize.width * viewScale
                    let cy = videoRect.minY + CGFloat(block.centerY) * model.renderSize.height * viewScale
                    let measured = TextImageRenderer.size(block, canvas: model.renderSize)
                    // While auto-wrapping, the box shows the wrap frame (boxWidth)
                    // so its edges are the draggable wrap width; otherwise it hugs
                    // the measured single-line text.
                    let frameW = block.autoWrap
                        ? CGFloat(block.boxWidth) * model.renderSize.width * viewScale
                        : measured.width * viewScale
                    let boxW = max(frameW, 44)
                    let boxH = max(measured.height * viewScale, 26)

                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .contentShape(Rectangle())            // whole box is draggable
                        .frame(width: boxW, height: boxH)
                        .overlay {
                            if block.autoWrap {
                                resizeHandle(block: block, viewScale: viewScale, leading: true)
                                    .position(x: 0, y: boxH / 2)
                                resizeHandle(block: block, viewScale: viewScale, leading: false)
                                    .position(x: boxW, y: boxH / 2)
                            }
                        }
                        .gesture(moveGesture(block: block, viewScale: viewScale))
                        // Consume single taps so a click on the box keeps the
                        // selection instead of falling through to the catcher.
                        .onTapGesture { model.selectTextBlock(block.id) }
                        .help("Drag to move · drag a side handle to resize the wrap width")
                        .position(x: cx, y: cy)
                }
```

- [ ] **Step 3: Add the handle view + resize gesture**

After `moveGesture` (after line 87), add:

```swift
    /// A small side handle that resizes the wrap width symmetrically about the
    /// block center.
    private func resizeHandle(block: TextBlock, viewScale: CGFloat, leading: Bool) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 6, height: 22)
            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: 18, height: 30)            // larger hit area
            .contentShape(Rectangle())
            .highPriorityGesture(resizeGesture(block: block, viewScale: viewScale, leading: leading))
    }

    private func resizeGesture(block: TextBlock, viewScale: CGFloat, leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                guard model.renderSize.width > 0 else { return }
                if resizeStartWidth == nil { resizeStartWidth = block.boxWidth }
                guard let start = resizeStartWidth else { return }
                // Center-anchored: a leading drag-left and a trailing drag-right
                // both widen; the factor of 2 keeps the box centered.
                let deltaFrac = Double(value.translation.width / viewScale) / model.renderSize.width
                let signed = leading ? -deltaFrac : deltaFrac
                model.setTextBoxWidth(start + 2 * signed)
            }
            .onEnded { _ in
                resizeStartWidth = nil
                model.commitTextEdit()
            }
    }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: succeeds. (`beginEditingText` is no longer called from the overlay; it still exists on the model until Task 5, so no break. The `.onTapGesture(count: 2)` double-click line was removed in Step 2.)

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/TextCanvasOverlay.swift
git commit -m "feat: resizable caption wrap box with side handles on the canvas

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Selection-driven inline editing (remove `editingTextBlockID`)

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift:54, 701-708, 718, 721-725, 749-762, 787-792, 811-816`
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift:44-49, 119-127, 361-375, 544-567`
- Modify: `Sources/CaptureStudio/Studio/TextCanvasOverlay.swift:48-56`
- Modify: `Sources/CaptureStudio/Studio/TextTimelineLane.swift:141-145`

**Interfaces:**
- Consumes: `model.selectedTextBlock`, `model.selectTextBlock(_:)`, `model.setText(_:for:)`, `model.commitTextEdit()`.
- Produces: editing is driven purely by selection. `editingTextBlockID`, `beginEditingText`, `endEditingText` are gone. The caption input is an inline `CaptionTextEditor` in the text tool group, shown only while a block is selected. Selecting/deselecting persists any live text edit.

This task is UI glue. Deliverable: `swift build` + `swift test` green, and editing works via the tool-group field. Apply all four files together so the build stays green.

- [ ] **Step 1: Remove `editingTextBlockID` and the begin/end-editing funcs in the model**

In `StudioModel.swift`:

Delete line 54:

```swift
    @Published var editingTextBlockID: UUID?
```

In `selectTextBlock` (lines 701-708), persist any live edit on the outgoing block. Replace:

```swift
    func selectTextBlock(_ id: UUID?) {
        selectedTextBlockID = id
        if id != nil { selectedBlockID = nil }
        if let id, let b = textBlocks.first(where: { $0.id == id }),
           !(b.begin <= currentTime && currentTime < b.end) {
            seek(to: min(b.begin, duration))
        }
    }
```

with:

```swift
    func selectTextBlock(_ id: UUID?) {
        if id != selectedTextBlockID { saveEdit() }   // persist the prior block's live text
        selectedTextBlockID = id
        if id != nil { selectedBlockID = nil }
        if let id, let b = textBlocks.first(where: { $0.id == id }),
           !(b.begin <= currentTime && currentTime < b.end) {
            seek(to: min(b.begin, duration))
        }
    }
```

In `addTextBlock`, delete the trailing line `editingTextBlockID = added.id` (added with a `(removed in Task 5)` note in Task 3).

In `removeTextBlock` (lines 721-725), delete the line:

```swift
        if editingTextBlockID == id { editingTextBlockID = nil }
```

Delete `beginEditingText` and `endEditingText` entirely (lines 749-762, including their doc comments):

```swift
    /// Open the text input popover for a block (select it and mark it editing).
    /// The input is off-canvas, so the baked text stays visible and updates live
    /// as the user types — no suppression needed.
    func beginEditingText(_ id: UUID) {
        selectTextBlock(id)
        editingTextBlockID = id
    }

    /// Close the text input popover and persist (text was applied live).
    func endEditingText() {
        guard editingTextBlockID != nil else { return }
        editingTextBlockID = nil
        saveEdit()
    }
```

In `beginDraggingText` (lines 787-792), delete the line:

```swift
        editingTextBlockID = nil
```

In `deselectText` (lines 811-816), replace:

```swift
    func deselectText() {
        if editingTextBlockID != nil { endEditingText() }
        if draggingTextBlockID != nil { endDraggingText() }
        selectedTextBlockID = nil
    }
```

with:

```swift
    func deselectText() {
        if draggingTextBlockID != nil { endDraggingText() }
        if selectedTextBlockID != nil { saveEdit() }   // persist any live text edit
        selectedTextBlockID = nil
    }
```

- [ ] **Step 2: Timeline block tap selects (no editor)**

In `TextTimelineLane.swift`, in `bodyGesture` `onEnded` (lines 141-145), replace:

```swift
            .onEnded { _ in
                // Tap (no drag) selects the block and opens its text input.
                if dragMoved { model.commitTextEdit() } else { model.beginEditingText(block.id) }
                dragMoved = false
            }
```

with:

```swift
            .onEnded { _ in
                // Tap (no drag) only selects; editing happens in the tool group.
                if dragMoved { model.commitTextEdit() } else { model.selectTextBlock(block.id) }
                dragMoved = false
            }
```

- [ ] **Step 3: Drop the canvas Return-deselect button**

In `TextCanvasOverlay.swift`, delete the `.background { ... }` modifier (lines 48-56) and its leading comment:

```swift
            .coordinateSpace(name: space)   // stable frame for the move drag
            // Return deselects the text block (Esc is handled globally by the
            // editor), but only when the text input is closed — it owns those
            // keys while open.
            .background {
                if model.editingTextBlockID == nil {
                    Button("") { model.deselectAll() }
                        .keyboardShortcut(.return, modifiers: []).opacity(0)
                }
            }
```

becomes just:

```swift
            .coordinateSpace(name: space)   // stable frame for the move drag
```

- [ ] **Step 4: Remove the timeline popover editor wiring in `StudioWindow`**

In `StudioWindow.swift`, replace the text-lane block (lines 119-127):

```swift
            if !model.textBlocks.isEmpty {
                laneRow("textformat") { TextTimelineLane(model: model) }
                    .popover(isPresented: Binding(
                        get: { model.editingTextBlockID != nil },
                        set: { if !$0 { model.endEditingText() } }
                    ), arrowEdge: .top) {
                        textEditorPopover
                    }
            }
```

with:

```swift
            if !model.textBlocks.isEmpty {
                laneRow("textformat") { TextTimelineLane(model: model) }
            }
```

- [ ] **Step 5: Gate the global Esc-deselect on selection (editor owns Esc while a block is selected)**

In `StudioWindow.swift`, replace lines 44-49:

```swift
        .background {
            if model.editingTextBlockID == nil {
                Button("") { model.deselectAll() }
                    .keyboardShortcut(.cancelAction).opacity(0)
            }
        }
```

with:

```swift
        .background {
            // The inline caption field owns Esc while a text block is selected.
            if model.selectedTextBlock == nil {
                Button("") { model.deselectAll() }
                    .keyboardShortcut(.cancelAction).opacity(0)
            }
        }
```

- [ ] **Step 6: Add the inline caption field to the text tool group**

In `StudioWindow.swift`, replace `textControls` (lines 361-375):

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

with:

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

        // Inline caption input — shown only while a text block is selected.
        // Selecting a block (timeline or canvas) reveals it; deselecting hides it.
        if model.selectedTextBlock != nil {
            CaptionTextEditor(
                text: Binding(
                    get: { model.selectedTextBlock?.text ?? "" },
                    set: { if let id = model.selectedTextBlockID { model.setText($0, for: id) } }
                ),
                onSubmit: { model.commitTextEdit() }
            )
            .frame(width: 220, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.secondary.opacity(0.3), lineWidth: 1))
            .help("Edit caption text · Shift+Return for a new line")
        }
    }
```

- [ ] **Step 7: Delete the now-unused popover editor**

In `StudioWindow.swift`, delete the `// MARK: - Text input` section and `textEditorPopover` (lines 544-567):

```swift
    // MARK: - Text input

    /// The dedicated caption input, shown as a popover off the text lane when a
    /// block is selected. Return / Esc / click-outside apply; Shift+Return adds
    /// a newline. Text updates the preview live as you type.
    @ViewBuilder
    private var textEditorPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Caption text").font(.caption).foregroundStyle(.secondary)
            CaptionTextEditor(
                text: Binding(
                    get: { model.selectedTextBlock?.text ?? "" },
                    set: { if let id = model.selectedTextBlockID { model.setText($0, for: id) } }
                ),
                onSubmit: { model.endEditingText() }
            )
            .frame(width: 280, height: 92)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.secondary.opacity(0.3), lineWidth: 1))
            Text("Return to apply · Shift+Return for a new line · Esc to apply")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
    }
```

- [ ] **Step 8: Build + full test**

Run: `swift build && swift test`
Expected: build succeeds (no remaining references to `editingTextBlockID` / `beginEditingText` / `endEditingText` / `textEditorPopover`); all tests PASS.

Sanity check there are no stragglers:

Run: `rg -n "editingTextBlockID|beginEditingText|endEditingText|textEditorPopover" Sources`
Expected: no matches.

- [ ] **Step 9: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift Sources/CaptureStudio/Studio/StudioWindow.swift Sources/CaptureStudio/Studio/TextCanvasOverlay.swift Sources/CaptureStudio/Studio/TextTimelineLane.swift
git commit -m "feat: selection-driven inline caption editing in the text tool group

Move the caption input out of the timeline popover and canvas double-click into
an inline field in the text tool group, shown only while a block is selected.
Timeline-block tap now only selects. Collapse editingTextBlockID into selection.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Px Size control + auto-wrap / box-width controls in the style popover

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift:627-630` (Size control) and the `textStylePopover` body

**Interfaces:**
- Consumes: `model.renderSize`, `model.setTextFontSize(_:)`, `model.commitTextEdit()`, `model.setTextAutoWrap(_:)`, `model.setTextBoxWidth(_:)`.
- Produces: Size shown as `NN px` with a slider (min `0.005`) + ±1px stepper; an Auto-wrap toggle; a Box width slider shown while auto-wrap is on.

UI glue. Deliverable: `swift build` succeeds and the controls display px / drive the model.

- [ ] **Step 1: Add a px-aware Size row helper**

In `StudioWindow.swift`, immediately after the `styleSliderText(_:value:range:)` helper (after line 679), add:

```swift
    /// Font-size control showing the rendered px height, with a ±1px stepper and
    /// a slider. `fontSize` is a fraction of canvas height, so px = fontSize ×
    /// renderSize.height (falls back to 1080 before the canvas size is known).
    @ViewBuilder
    private func textSizeRow(_ block: TextBlock?) -> some View {
        let h = model.renderSize.height > 0 ? model.renderSize.height : 1080
        let frac = block?.fontSize ?? 0.06
        let px = Int((frac * h).rounded())
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(px) px").font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("", value: Binding(
                    get: { Double(px) },
                    set: { model.setTextFontSize($0 / h); model.commitTextEdit() }
                ), in: 1...h, step: 1)
                .labelsHidden()
            }
            Slider(value: Binding(
                get: { block?.fontSize ?? 0.06 },
                set: { model.setTextFontSize($0) }
            ), in: 0.005...0.2) { editing in
                if !editing { model.commitTextEdit() }
            }
        }
    }
```

- [ ] **Step 2: Use it in the style popover**

In `textStylePopover`, replace the Size slider (lines 627-630):

```swift
                styleSliderText("Size", value: Binding(
                    get: { block?.fontSize ?? 0.06 },
                    set: { model.setTextFontSize($0) }
                ), range: 0.02...0.2)
```

with:

```swift
                textSizeRow(block)

                Toggle("Auto-wrap lines", isOn: Binding(
                    get: { block?.autoWrap ?? true },
                    set: { model.setTextAutoWrap($0) }
                ))
                if block?.autoWrap ?? true {
                    styleSliderText("Box width", value: Binding(
                        get: { block?.boxWidth ?? 0.9 },
                        set: { model.setTextBoxWidth($0) }
                    ), range: 0.05...1.0)
                }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "feat: show caption font size in px; add auto-wrap toggle and box-width control

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Full verification + manual smoke test

**Files:** none (verification only).

- [ ] **Step 1: Full build + test**

Run: `swift build && swift test`
Expected: build succeeds; all tests PASS (109 prior + the new EditState/Renderer/Timeline tests).

- [ ] **Step 2: Package and launch the app**

Run: `scripts/build-app.sh debug && pkill -x CaptureStudio; open dist/CaptureStudio.app`
Expected: app launches from the menu bar.

- [ ] **Step 3: Manual smoke checklist**

Open a recording in Studio and confirm:
- Add a text block → the inline caption field appears in the text tool group and is focused; type and it shows on the canvas live.
- Open the style popover → Size shows `NN px`; the ±1px stepper and the slider both change size; you can go smaller than before (down to ~5–6 px at 1080-tall output).
- Edit a block's color/size/box, then Add another block → the new block clones the last block's style **and position** (stacks on top), with empty text.
- Toggle "Auto-wrap lines" off → a long line stops wrapping and extends past the canvas; toggle on → it wraps again.
- With auto-wrap on, drag the canvas side handles → the wrap width changes (text re-wraps), font size unchanged; the "Box width" slider mirrors it.
- Click a block in the timeline → it only selects (no separate editor opens); the inline tool-group field shows its text. Click empty canvas → deselects and the field hides.

- [ ] **Step 4: Update project docs (optional but expected)**

If the smoke test passes, note the new text-tool behavior in `CLAUDE.md` / `README` where the Studio text/caption tooling is described (inline tool-group caption field, px size, resizable wrap box, auto-wrap). Commit separately:

```bash
git add CLAUDE.md README.md
git commit -m "docs: describe inline caption editing, px size, and resizable wrap box

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review notes

- **Spec coverage:** #1 inheritance → Task 3 (`lastTextStyle`, `addTextBlock`). #2 smaller min → Task 3 (clamp) + Task 6 (slider min). #3 px → Task 6 (`textSizeRow`). #4 resize box → Task 1 (`boxWidth`) + Task 2 (renderer) + Task 4 (handles) + Task 6 (slider). #5 auto-wrap → Task 1 (`autoWrap`) + Task 2 (renderer) + Task 6 (toggle). #6 inline edit / select-only → Task 5.
- **Build-green ordering:** `editingTextBlockID` survives until Task 5, which removes it and all four call sites in one commit. Task 4 stops calling `beginEditingText` (via the removed double-click) but the symbol still exists, so it compiles.
- **Type consistency:** `boxWidth`/`autoWrap` names, `setTextBoxWidth`/`setTextAutoWrap` signatures, and `textSizeRow(_:)` match across tasks.
- **Persistence of live text:** committed on `selectTextBlock` change, `deselectText`, `commitTextEdit` (field submit), and `setTextBlocks` (add/remove/z-order) — no keystroke-level writes.
