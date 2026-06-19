# Area Selection Merged Into Preview — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make area-capture's region selection a live, editable overlay that runs *during* the preview, so the user opens one button, adjusts the area while the camera preview shows, and records from the tray (or Return) with no confirm button in the overlay bar.

**Architecture:** Repurpose the modal `AreaSelector.Coordinator` into a session-owned, long-lived `AreaSelectionOverlay` that reports the live region via callbacks. The `ScreenRecorder` and `DisplayInfo` are no longer built at `arm()` time for interactive area — they are deferred and constructed from the *final* selection when recording starts. Full-display mode and the global hotkey are untouched.

**Tech Stack:** Swift 6 (Command Line Tools toolchain), SwiftUI + AppKit (`NSPanel` overlays), ScreenCaptureKit, swift-testing.

## Global Constraints

Copied verbatim from the spec and `CLAUDE.md`; every task inherits these.

- Toolchain: **Command Line Tools only, no Xcode.app.** Do not bump swift-testing (`0.12.0`) or KeyboardShortcuts (`1.10.0`).
- Build/test: `swift build` and `swift test` must stay green (currently **45 tests**).
- App build for manual verification: `scripts/build-app.sh debug`, then `pkill -x CaptureStudio; open dist/CaptureStudio.app`.
- Architecture invariants (do not regress): cursor not baked in; host-clock sync; region-relative `DisplayInfo` (schema unchanged — only values); own-app windows excluded from capture; preview/record split; **area capture display = the drag, not the picker**.
- Project convention: capture/UI glue is **not** unit-tested — only pure helpers are. Where a task is UI glue, the test cycle is `swift build` + `swift test` green plus the manual checklist; add a swift-testing case only for an extracted pure helper.
- Locked copy: overlay bar hint **"Enter to record · Esc to cancel"**; armed-view header for interactive area **"Adjust area, then record"**.
- Commit messages: normal English, end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. **Never push.** **Never commit without explicit user confirmation** — every "Commit" step below is gated on the user saying yes.

---

## File map

- **Modify** `Sources/CaptureStudio/App/RegionEditState.swift` — add `isValid` pure helper.
- **Modify** `Tests/CaptureStudioTests/RegionEditStateTests.swift` — test `isValid`.
- **Modify** `Sources/CaptureStudio/App/AreaControlBar.swift` — drop Use Area / Cancel buttons, add hint, rename `canConfirm` → `valid`, drop `onConfirm`/`onCancel` from the model.
- **Rewrite** `Sources/CaptureStudio/App/AreaSelector.swift` — `AreaSelector.Coordinator` → long-lived `AreaSelectionOverlay` with `present`/`dismiss` + `onChange`/`onCancel`/`onStart`; remove the `selectRegion()` modal and the `withCheckedContinuation`.
- **Modify** `Sources/CaptureStudio/Recorder/RecordingSession.swift` — `interactiveArea` plumbing, `canBeginArmed` + `armedAreaSize` published state, interactive-area arm branch, deferred screen-recorder build at record time, teardown wiring.
- **Modify** `Sources/CaptureStudio/App/RecorderMenuView.swift` — primary button label, remove the Select Area row, gate the Record button, armed-view copy + live size, pass `interactiveArea`.

---

## Task 1: `RegionEditState.isValid` pure helper

A single source of truth for "is this rect big enough to use", reused by the overlay's change emitter and the control bar. Pure geometry → real TDD.

**Files:**
- Modify: `Sources/CaptureStudio/App/RegionEditState.swift`
- Test: `Tests/CaptureStudioTests/RegionEditStateTests.swift`

**Interfaces:**
- Produces: `RegionEditState.isValid: Bool` — `true` iff `rect.width >= minSize && rect.height >= minSize`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CaptureStudioTests/RegionEditStateTests.swift`, inside `struct RegionEditStateTests`:

```swift
    // MARK: isValid

    @Test func isValidTrueWhenAtLeastMinSize() {
        let s = state(CGRect(x: 0, y: 0, width: 20, height: 20))  // minSize == 20
        #expect(s.isValid)
    }

    @Test func isValidFalseWhenNarrowerThanMinSize() {
        let s = state(CGRect(x: 0, y: 0, width: 19, height: 200))
        #expect(!s.isValid)
    }

    @Test func isValidFalseWhenShorterThanMinSize() {
        let s = state(CGRect(x: 0, y: 0, width: 200, height: 19))
        #expect(!s.isValid)
    }

    @Test func isValidFalseForZeroRect() {
        let s = state(.zero)
        #expect(!s.isValid)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RegionEditStateTests`
Expected: FAIL — `value of type 'RegionEditState' has no member 'isValid'`.

- [ ] **Step 3: Add the implementation**

In `Sources/CaptureStudio/App/RegionEditState.swift`, add inside `struct RegionEditState` (e.g. just after the stored properties, before `// MARK: Draw`):

```swift
    /// True once the selection is at least `minSize` in both dimensions — the
    /// threshold for committing it (drives the control bar and Start Record).
    var isValid: Bool { rect.width >= minSize && rect.height >= minSize }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter RegionEditStateTests`
Expected: PASS (all existing RegionEditState tests + the 4 new ones).

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS, 49 tests (45 + 4).

- [ ] **Step 6: Commit (after user confirmation)**

```bash
git add Sources/CaptureStudio/App/RegionEditState.swift Tests/CaptureStudioTests/RegionEditStateTests.swift
git commit -m "Add RegionEditState.isValid for selection-commit threshold

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: Control bar — drop confirm/cancel, add hint, expose `valid`

The bar becomes display-only: aspect chips + live size + a hint. No buttons.

**Files:**
- Modify: `Sources/CaptureStudio/App/AreaControlBar.swift`

**Interfaces:**
- Produces: `AreaControlModel` with `@Published var sizeText`, `@Published var valid: Bool`, `@Published var aspect: AspectRatio`, and `var onPickAspect: (AspectRatio) -> Void`. (Removes `canConfirm`, `onConfirm`, `onCancel`.)
- Consumes: nothing new.

- [ ] **Step 1: Replace the model**

In `Sources/CaptureStudio/App/AreaControlBar.swift`, replace the `AreaControlModel` class with:

```swift
@MainActor
final class AreaControlModel: ObservableObject {
    @Published var sizeText: String = ""
    /// Selection is at least `minSize` in both dimensions (mirrors
    /// `RegionEditState.isValid`). Reported to the session; not shown in the bar.
    @Published var valid: Bool = false
    @Published var aspect: AspectRatio = .free

    var onPickAspect: (AspectRatio) -> Void = { _ in }
}
```

- [ ] **Step 2: Replace the bar body**

Replace the `body` of `AreaControlBar` (drop the Divider/Cancel/Use Area trailing section, keep chips + readout, add the hint):

```swift
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(AspectRatio.all, id: \.label) { ratio in
                    chip(ratio)
                }
            }

            Divider().frame(height: 16).overlay(.white.opacity(0.25))

            Text(model.sizeText.isEmpty ? "Drag to select" : model.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .frame(minWidth: 96, alignment: .leading)

            Divider().frame(height: 16).overlay(.white.opacity(0.25))

            Text("Enter to record · Esc to cancel")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .fixedSize()
    }
```

(The `chip(_:)` helper and the private `AspectRatio.hint` extension are unchanged.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: FAIL to compile — `AreaSelector.swift` still references `model.canConfirm`, `model.onConfirm`, `model.onCancel`. That is expected; Task 3 rewrites that file. Do **not** patch `AreaSelector.swift` here.

> Note: Tasks 2–4 form one compile-coupled change (the modal is being deleted and its consumers rewired). The build only returns green at the end of Task 4. Commit Task 2 alongside Tasks 3–4 — see Task 4, Step "Commit". This step's "expected failure" simply confirms the only break is the intended one.

---

## Task 3: Rewrite `AreaSelector.swift` → `AreaSelectionOverlay`

Turn the one-shot modal coordinator into a long-lived overlay the session owns. Same panels, dim, gesture math, and aspect handling; new lifecycle and callbacks.

**Files:**
- Rewrite: `Sources/CaptureStudio/App/AreaSelector.swift`

**Interfaces:**
- Produces:
  - `final class AreaSelectionOverlay` (`@MainActor`) with:
    - `var onChange: (_ region: CGRect?, _ displayID: CGDirectDisplayID?, _ valid: Bool) -> Void`
    - `var onCancel: () -> Void`
    - `var onStart: () -> Void`
    - `func present(initialRegion: CGRect?, initialDisplayID: CGDirectDisplayID?)`
    - `func dismiss()`
  - `final class SelectionView: NSView` (unchanged rendering/gesture forwarding; `coordinator` retyped to `AreaSelectionOverlay`).
- Consumes: `RegionEditState.isValid` (Task 1), `AreaControlModel` (Task 2).

- [ ] **Step 1: Replace the whole file**

Replace the entire contents of `Sources/CaptureStudio/App/AreaSelector.swift` with:

```swift
import AppKit
import SwiftUI

/// Live, session-owned area-selection overlay. Dims **every** screen with a
/// single overlay session; the user drags a rectangle on whichever screen they
/// like and keeps editing it (move, resize from eight handles, redraw, or apply
/// an aspect-ratio template) for as long as the overlay is up. The screen the
/// selection lands on **is** the capture display. Unlike the old modal, there is
/// no confirm button: every change is reported live via `onChange`, Return fires
/// `onStart`, and ESC / right-click fires `onCancel`. The session decides what to
/// do with those. Coordinates are reported in **display-local points** (top-left
/// origin within that display) together with the display id.
@MainActor
final class AreaSelectionOverlay {
    /// Minimum selection size (points); a smaller drag never qualifies as valid.
    static let minSize: CGFloat = 20

    /// Fired on every drag/resize/aspect/screen change. `region`/`displayID` are
    /// nil before the first qualifying selection exists.
    var onChange: (_ region: CGRect?, _ displayID: CGDirectDisplayID?, _ valid: Bool) -> Void = { _, _, _ in }
    /// ESC / right-click / cancelOperation.
    var onCancel: () -> Void = {}
    /// Return / keypad Enter — the session ignores it unless a valid region exists.
    var onStart: () -> Void = {}

    private enum DragMode {
        case draw(anchor: CGPoint)
        case move(last: CGPoint)
        case resize(Handle)
    }

    private var panels: [(panel: NSPanel, view: SelectionView, screen: NSScreen)] = []
    private var controlPanel: NSPanel?
    private let model = AreaControlModel()
    private var priorApp: NSRunningApplication?
    private var keyMonitor: Any?
    private let minSize = AreaSelectionOverlay.minSize

    private var state: RegionEditState?
    private var activeScreen: NSScreen?
    private var aspect: AspectRatio = .free
    private var dragMode: DragMode?
    private var preDrawState: RegionEditState?
    private var preDrawScreen: NSScreen?

    private let handleRadius: CGFloat = 9

    // MARK: Presentation

    func present(initialRegion: CGRect?, initialDisplayID: CGDirectDisplayID?) {
        priorApp = NSWorkspace.shared.frontmostApplication

        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.coordinator = self
            view.screen = screen
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append((panel, view, screen))
        }

        model.onPickAspect = { [weak self] in self?.pickAspect($0) }

        // Seed the saved region (if any) so the user starts from last time's box.
        seed(region: initialRegion, displayID: initialDisplayID)

        presentControlBar(on: activeScreen ?? NSScreen.main ?? NSScreen.screens.first)
        refreshControlBar()
        emitChange()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53:            // Escape
                self?.onCancel(); return nil
            case 36, 76:        // Return, keypad Enter
                self?.onStart(); return nil
            default:
                return event
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        panels.first?.panel.makeKey()
    }

    /// Tear down all panels and the key monitor, restore prior focus. Idempotent.
    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for entry in panels { entry.panel.orderOut(nil) }
        panels.removeAll()
        controlPanel?.orderOut(nil)
        controlPanel = nil
        priorApp?.activate()
        priorApp = nil
    }

    /// Place `region` on the screen matching `displayID` as the starting box.
    private func seed(region: CGRect?, displayID: CGDirectDisplayID?) {
        guard let region, let displayID,
              let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        activeScreen = screen
        state = RegionEditState(bounds: screen.frame.size, rect: region,
                                aspect: .free, minSize: minSize)
    }

    private func presentControlBar(on screen: NSScreen?) {
        let host = NSHostingView(rootView: AreaControlBar(model: model))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = host
        controlPanel = panel
        positionControlBar(on: screen)
        panel.orderFrontRegardless()
    }

    private func positionControlBar(on screen: NSScreen?) {
        guard let controlPanel, let screen else { return }
        let size = controlPanel.frame.size
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.minY + 72
        controlPanel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    // MARK: Selection access (for SelectionView rendering)

    func selection(on screen: NSScreen) -> RegionEditState? {
        activeScreen === screen ? state : nil
    }

    func handleRadiusForDrawing() -> CGFloat { handleRadius }

    // MARK: Gesture forwarding (points are screen-local, top-left, y-down)

    func pointerDown(at point: CGPoint, on screen: NSScreen) {
        if activeScreen !== screen {
            state = nil
            activeScreen = screen
            positionControlBar(on: screen)
        }

        if let current = state, let hit = current.hitTest(point, handleRadius: handleRadius) {
            switch hit {
            case .handle(let h): dragMode = .resize(h)
            case .move: dragMode = .move(last: point)
            }
        } else {
            startDraw(at: point, on: screen)
        }
    }

    func pointerDragged(to point: CGPoint) {
        switch dragMode {
        case .draw(let anchor):
            state?.drawFrom(anchor, to: point)
        case .move(let last):
            state?.move(by: CGSize(width: point.x - last.x, height: point.y - last.y))
            dragMode = .move(last: point)
        case .resize(let handle):
            state?.resize(handle, to: point)
        case nil:
            break
        }
        redrawAll()
        refreshControlBar()
        emitChange()
    }

    func pointerUp() {
        if case .draw = dragMode, let s = state, !s.isValid {
            state = preDrawState
            activeScreen = preDrawScreen ?? activeScreen
        }
        dragMode = nil
        preDrawState = nil
        preDrawScreen = nil
        redrawAll()
        refreshControlBar()
        emitChange()
    }

    private func startDraw(at point: CGPoint, on screen: NSScreen) {
        preDrawState = state
        preDrawScreen = activeScreen
        var fresh = RegionEditState(bounds: screen.frame.size,
                                    rect: CGRect(origin: point, size: .zero),
                                    aspect: aspect, minSize: minSize)
        fresh.drawFrom(point, to: point)
        state = fresh
        activeScreen = screen
        dragMode = .draw(anchor: point)
    }

    private func pickAspect(_ ratio: AspectRatio) {
        aspect = ratio
        if state != nil {
            state?.applyAspect(ratio)
        } else if ratio.value != nil,
                  let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens.first {
            activeScreen = screen
            let size = screen.frame.size
            var fresh = RegionEditState(bounds: size,
                                        rect: CGRect(x: size.width / 2, y: size.height / 2,
                                                     width: 0, height: 0),
                                        aspect: ratio, minSize: minSize)
            fresh.applyAspect(ratio)
            state = fresh
            positionControlBar(on: screen)
        }
        redrawAll()
        refreshControlBar()
        emitChange()
    }

    // MARK: Refresh

    private func redrawAll() {
        for entry in panels { entry.view.needsDisplay = true }
    }

    private func refreshControlBar() {
        model.aspect = aspect
        if let s = state, s.isValid {
            model.sizeText = "\(Int(s.rect.width.rounded())) × \(Int(s.rect.height.rounded()))"
            model.valid = true
        } else {
            model.sizeText = ""
            model.valid = false
        }
    }

    /// Report the live region + display + validity to the session.
    private func emitChange() {
        guard let state, let screen = activeScreen, let displayID = screen.displayID,
              state.isValid else {
            onChange(nil, nil, false)
            return
        }
        onChange(state.rect, displayID, true)
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Renders the dim backdrop + the (optional) selection rect with eight handles and
/// a W×H readout, and forwards mouse gestures to the overlay in screen-local,
/// top-left, y-down points. Holds no selection state of its own.
final class SelectionView: NSView {
    weak var coordinator: AreaSelectionOverlay?
    var screen: NSScreen?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func localPoint(_ event: NSEvent) -> CGPoint {
        let v = convert(event.locationInWindow, from: nil)
        return CGPoint(x: v.x, y: bounds.height - v.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard let screen else { return }
        coordinator?.pointerDown(at: localPoint(event), on: screen)
    }

    override func mouseDragged(with event: NSEvent) {
        coordinator?.pointerDragged(to: localPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        coordinator?.pointerUp()
    }

    override func rightMouseDown(with event: NSEvent) { coordinator?.onCancel() }
    override func cancelOperation(_ sender: Any?) { coordinator?.onCancel() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let screen,
              let state = coordinator?.selection(on: screen),
              state.rect.width > 0, state.rect.height > 0 else { return }

        let r = state.rect
        let viewRect = NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)

        NSColor.clear.set()
        viewRect.fill(using: .copy)

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: viewRect)
        border.lineWidth = 1.5
        border.stroke()

        drawHandles(state)
        drawReadout(viewRect)
    }

    private func drawHandles(_ state: RegionEditState) {
        let s: CGFloat = 8
        for handle in Handle.allCases {
            let c = state.handlePoint(handle)
            let cv = CGPoint(x: c.x, y: bounds.height - c.y)
            let box = NSRect(x: cv.x - s / 2, y: cv.y - s / 2, width: s, height: s)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            let outline = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    private func drawReadout(_ viewRect: NSRect) {
        let label = "\(Int(viewRect.width.rounded())) × \(Int(viewRect.height.rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let boxW = size.width + pad * 2
        let boxH = size.height + pad
        var boxX = viewRect.midX - boxW / 2
        var boxY = viewRect.minY - boxH - 6
        boxX = max(bounds.minX + 4, min(boxX, bounds.maxX - boxW - 4))
        if boxY < bounds.minY + 4 { boxY = viewRect.maxY + 6 }
        let box = NSRect(x: boxX, y: boxY, width: boxW, height: boxH)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad / 2), withAttributes: attrs)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: FAIL — `RecordingSession.swift` and `RecorderMenuView.swift` still reference the removed `AreaSelector.selectRegion`. Expected; Tasks 4 (session) and the menu close the loop. Continue to Task 4 before building green.

---

## Task 4: Session + menu rewire (deferred recorder, live region, gating)

Thread `interactiveArea` through, add the interactive arm branch (no screen recorder built), publish `canBeginArmed` + `armedAreaSize`, build the screen recorder from the final selection at record time, and update the menu (button label, removed row, gated Record, armed copy). This is the task that makes the build green again.

**Files:**
- Modify: `Sources/CaptureStudio/Recorder/RecordingSession.swift`
- Modify: `Sources/CaptureStudio/App/RecorderMenuView.swift`

**Interfaces:**
- Consumes: `AreaSelectionOverlay` (Task 3), `RegionEditState.isValid` (Task 1), `DisplayItem.clampedRegion` / `displayInfo(region:)`, `ScreenRecorder(display:item:outputURL:systemAudioURL:region:)`, `RegionOutlineOverlay(region:onDisplay:)`.
- Produces (on `RecordingSession`):
  - `@Published private(set) var canBeginArmed: Bool` — gates the Record button.
  - `@Published private(set) var armedAreaSize: CGSize?` — live size for the armed view.
  - `toggle(..., interactiveArea: Bool = false)` and `arm(..., interactiveArea: Bool = false)`.

### Session changes — `RecordingSession.swift`

- [ ] **Step 1: Add published state + stash fields**

After the existing `@Published private(set) var counting = false` (line ~27), add:

```swift
    /// Whether Record may fire. Always true for non-interactive paths; for
    /// interactive area it mirrors the live overlay's validity.
    @Published private(set) var canBeginArmed: Bool = true
    /// Live size of the interactive-area selection, for the armed view. nil
    /// outside interactive area or before a valid drag.
    @Published private(set) var armedAreaSize: CGSize?
```

Alongside the existing private overlay fields (near `previewPanel` / `regionOutline` / `dimOverlay`, line ~41-43), add:

```swift
    private var areaOverlay: AreaSelectionOverlay?
    /// System-audio choice stashed for the deferred screen-recorder build.
    private var armedSystemAudio = false
```

- [ ] **Step 2: Branch `arm()` into the interactive path**

Change the `arm` signature to add the flag, and branch at the very top of the body (right after `state = .arming; warnings = []` and the log line):

```swift
    func arm(displayID: CGDirectDisplayID,
             cameraID: String? = nil,
             micID: String? = nil,
             systemAudio: Bool = false,
             region: CGRect? = nil,
             previewDim: Bool = false,
             interactiveArea: Bool = false) async {
        guard state == .idle || isFailed else { return }
        state = .arming
        warnings = []
        Log.recorder.info("arm: display=\(displayID) camera=\(cameraID ?? "none", privacy: .public) mic=\(micID ?? "none", privacy: .public) systemAudio=\(systemAudio) region=\(region != nil) interactive=\(interactiveArea)")

        if interactiveArea {
            await armInteractiveArea(displayID: displayID, cameraID: cameraID, micID: micID,
                                     systemAudio: systemAudio, region: region)
            return
        }

        // ... existing body unchanged from here ...
```

> The existing non-interactive body (display resolution, screen-recorder construction, camera/mic warm-up, outline, dim, `state = .armed`) is left exactly as-is below the branch.

- [ ] **Step 3: Add `armInteractiveArea`**

Add this method to `RecordingSession` (e.g. just after `arm`). It warms camera/mic + preview but builds **no** screen recorder and presents the live overlay:

```swift
    /// Interactive-area arm: warm camera/mic + show the camera preview, present
    /// the live `AreaSelectionOverlay`, and defer the screen recorder /
    /// displayInfo to record time (the region isn't final yet). → `.armed`.
    private func armInteractiveArea(displayID: CGDirectDisplayID?,
                                    cameraID: String?, micID: String?,
                                    systemAudio: Bool, region: CGRect?) async {
        do {
            try FileManager.default.createDirectory(
                at: ProjectBundle.defaultRecordingsDirectory(),
                withIntermediateDirectories: true
            )
            let bundle = try ProjectBundle.createNew()

            let micDevice = micID.flatMap { id in
                DeviceDiscovery.microphones().first { $0.uniqueID == id }
            }
            let cameraDevice = cameraID.flatMap { id in
                DeviceDiscovery.cameras().first { $0.uniqueID == id }
            }

            if let cameraDevice {
                let recorder = CameraRecorder(
                    device: cameraDevice, outputURL: bundle.cameraURL,
                    micDevice: micDevice,
                    micOutputURL: micDevice != nil ? bundle.micURL : nil
                )
                do {
                    try await recorder.warmUp()
                    cameraRecorder = recorder
                    let panel = CameraPreviewPanel(session: recorder.captureSession,
                                                   onDisplay: displayID)
                    panel.show()
                    previewPanel = panel
                    if recorder.micWarning != nil, let micDevice {
                        await warmUpStandaloneMic(micDevice, bundle: bundle)
                    }
                } catch {
                    Log.recorder.error("camera warm-up failed: \(error.localizedDescription, privacy: .public)")
                    warnings.append("Camera not recorded: \(error.localizedDescription)")
                    if let micDevice { await warmUpStandaloneMic(micDevice, bundle: bundle) }
                }
            } else if let micDevice {
                await warmUpStandaloneMic(micDevice, bundle: bundle)
            }

            let overlay = AreaSelectionOverlay()
            overlay.onChange = { [weak self] region, did, valid in
                guard let self else { return }
                self.armedRegion = region
                self.armedDisplayID = did
                self.armedAreaSize = valid ? region?.size : nil
                self.canBeginArmed = valid
            }
            overlay.onCancel = { [weak self] in
                Task { await self?.cancelCountdownOrArming() }
            }
            overlay.onStart = { [weak self] in
                Task { await self?.startCountdownThenBegin() }
            }

            self.bundle = bundle
            self.screenRecorder = nil
            self.displayInfo = nil
            self.armedSystemAudio = systemAudio
            self.armedRegion = region
            self.armedDisplayID = displayID
            self.armedAreaSize = nil
            self.canBeginArmed = false
            self.areaOverlay = overlay
            state = .armed
            overlay.present(initialRegion: region, initialDisplayID: displayID)
            Log.recorder.info("armed (interactive area): \(bundle.url.lastPathComponent, privacy: .public)")
        } catch {
            Log.recorder.error("arm (interactive area) failed: \(error.localizedDescription, privacy: .public)")
            await tearDownArmed()
            state = .failed(error.localizedDescription)
        }
    }
```

- [ ] **Step 4: Add the deferred screen-recorder builder**

Add this method (e.g. after `armInteractiveArea`). It resolves the final display, builds the recorder + `displayInfo`, persists the region, and swaps the live overlay for the static outline:

```swift
    /// Builds the screen recorder from the final interactive-area selection at
    /// record time. Returns false (and sets `.failed`) if the display vanished.
    private func buildDeferredScreenRecorder() async -> Bool {
        guard let bundle, let displayID = armedDisplayID else {
            state = .failed("No area selected.")
            return false
        }
        do {
            let (items, scDisplays) = try await DeviceDiscovery.displays()
            guard let item = items.first(where: { $0.id == displayID }),
                  let scDisplay = scDisplays[displayID] else {
                state = .failed("Selected display is no longer available.")
                return false
            }
            // nil here means the drag covered the whole display → full-display
            // capture, which is valid (just no region outline).
            let region = item.clampedRegion(armedRegion)

            let screen = ScreenRecorder(
                display: scDisplay, item: item, outputURL: bundle.screenURL,
                systemAudioURL: armedSystemAudio ? bundle.systemAudioURL : nil,
                region: region
            )
            screen.onStreamError = { [weak self] error in
                Task { @MainActor in await self?.stop(streamError: error) }
            }

            self.screenRecorder = screen
            self.displayInfo = item.displayInfo(region: region)
            self.armedRegion = region

            AppSettings.captureRegion = region
            AppSettings.captureRegionDisplayID = displayID

            areaOverlay?.dismiss()
            areaOverlay = nil
            if let region {
                let outline = RegionOutlineOverlay(region: region, onDisplay: displayID)
                outline?.show()
                regionOutline = outline
            }
            return true
        } catch {
            Log.recorder.error("deferred screen recorder build failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            return false
        }
    }
```

- [ ] **Step 5: Build the recorder before the countdown**

In `startCountdownThenBegin()`, after `counting = true` and **before** dropping the dim / starting the countdown, insert the deferred build:

```swift
    func startCountdownThenBegin() async {
        guard isArmed, !counting else { return }
        counting = true

        // Interactive area defers the screen recorder until the region is final.
        if screenRecorder == nil {
            guard await buildDeferredScreenRecorder() else {
                counting = false
                return
            }
        }

        // Preview's over — drop the dim before the countdown / recording shows.
        dimOverlay?.close()
        dimOverlay = nil
        // ... rest unchanged (region = armedRegion; displayID = armedDisplayID;
        //     countdown task; beginRecording) ...
```

> If `buildDeferredScreenRecorder` set `.failed`, returning early with `counting = false` leaves the menu showing the failure. The live overlay is already torn down only on success; on failure it is left up — see Step 6 teardown, which also closes it.

- [ ] **Step 6: Close the overlay in every teardown path**

In `tearDownArmed()`, add overlay close + reset gating, next to the existing `previewPanel?.close()` block:

```swift
        areaOverlay?.dismiss()
        areaOverlay = nil
        canBeginArmed = true
        armedAreaSize = nil
        armedSystemAudio = false
```

In `stop(...)` final cleanup block (where `previewPanel?.close()` etc. run) add:

```swift
        areaOverlay?.dismiss()
        areaOverlay = nil
        canBeginArmed = true
        armedAreaSize = nil
```

In `tearDownForQuit()` add:

```swift
        areaOverlay?.dismiss()
        areaOverlay = nil
```

- [ ] **Step 7: Thread `interactiveArea` through `toggle` / `startFromIdle`**

Update `toggle` to accept and forward the flag:

```swift
    func toggle(displayID: CGDirectDisplayID?, cameraID: String?, micID: String?,
                systemAudio: Bool, region: CGRect? = nil, activateForPrompts: Bool,
                previewFirst: Bool = false, interactiveArea: Bool = false) async {
        switch state {
        case .recording:
            await stop()
        case .armed where counting:
            await cancelCountdownOrArming()
        case .armed:
            await startCountdownThenBegin()
        case .idle, .failed:
            await startFromIdle(displayID: displayID, cameraID: cameraID, micID: micID,
                                systemAudio: systemAudio, region: region,
                                activateForPrompts: activateForPrompts,
                                previewFirst: previewFirst, interactiveArea: interactiveArea)
        case .arming, .preparing, .finishing:
            return
        }
    }
```

Update `startFromIdle` to accept the flag and pass it to `arm` (and force preview for interactive area):

```swift
    private func startFromIdle(displayID: CGDirectDisplayID?, cameraID: String?,
                               micID: String?, systemAudio: Bool, region: CGRect?,
                               activateForPrompts: Bool, previewFirst: Bool,
                               interactiveArea: Bool = false) async {
        guard Permissions.screenRecordingGranted() else { return }
        guard let displayID else { return }

        var camera = cameraID
        var mic = micID
        if camera != nil || mic != nil, activateForPrompts {
            NSApp.activate(ignoringOtherApps: true)
        }
        if camera != nil, await !Permissions.requestCapture(.video) { camera = nil }
        if mic != nil, await !Permissions.requestCapture(.audio) { mic = nil }

        let willPreview = camera != nil || previewFirst
        await arm(displayID: displayID, cameraID: camera, micID: mic,
                  systemAudio: systemAudio, region: region,
                  previewDim: willPreview && !interactiveArea,
                  interactiveArea: interactiveArea)

        if camera == nil, !previewFirst, isArmed {
            await startCountdownThenBegin()
        }
    }
```

> `previewDim: willPreview && !interactiveArea` — interactive area uses the overlay's own dim, so the separate `CaptureDimOverlay` must not also appear.

`toggleFromHotkey` is unchanged: it never passes `interactiveArea`, so it stays `false` (the hotkey can't pop an interactive selector).

### Menu changes — `RecorderMenuView.swift`

- [ ] **Step 8: Replace `captureModeRow`'s area block with a readout**

In `RecorderMenuView.swift`, replace the `if captureAreaEnabled { ... }` block inside `captureModeRow` (the `Select Area…` / `Reselect Area…` button + size chip) with a readout-only row:

```swift
        if captureAreaEnabled {
            HStack(spacing: 6) {
                Image(systemName: "selection.pin.in.out")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("Area")
                Spacer()
                if let r = captureRegion {
                    Text("\(areaDisplayName) · \(Int(r.width))×\(Int(r.height))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                } else {
                    Text("Not set")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.caption)
        }
```

> The old code had no `AreaSelector.selectRegion` call left anywhere — this removes the last GUI caller of the deleted modal.

- [ ] **Step 9: Primary button — label, enablement, interactive flag**

Replace the idle-view primary button (`Label("Preview", systemImage: "eye")` block) with:

```swift
            Button {
                elapsed = 0
                let region = captureAreaEnabled ? captureRegion : nil
                let useDisplay = captureAreaEnabled ? captureRegionDisplayID : selectedDisplayID
                Task {
                    await session.toggle(displayID: useDisplay,
                                         cameraID: selectedCameraID,
                                         micID: selectedMicID,
                                         systemAudio: systemAudioEnabled,
                                         region: region,
                                         activateForPrompts: false,
                                         previewFirst: true,
                                         interactiveArea: captureAreaEnabled)
                }
            } label: {
                Label(captureAreaEnabled ? "Preview / Select Area" : "Preview",
                      systemImage: captureAreaEnabled ? "crop" : "eye")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(captureAreaEnabled ? false : selectedDisplayID == nil)
            .padding(.top, 4)
```

> Area mode no longer requires a saved region to start (the user draws it live), so its disabled condition is `false`. For interactive area, `useDisplay` may be nil (no saved region); that's fine — `startFromIdle`'s `guard let displayID` would no-op, so when `captureRegionDisplayID` is nil, pass `selectedDisplayID` as a fallback seed instead:

Change the `useDisplay` line to:

```swift
                let useDisplay = captureAreaEnabled
                    ? (captureRegionDisplayID ?? selectedDisplayID)
                    : selectedDisplayID
```

- [ ] **Step 10: Armed-view copy + live size + gated Record**

Replace `armedView` with:

```swift
    private var armedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(armedHeader, systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(session.counting ? Color.secondary : Color.green)

            if let sz = session.armedAreaSize {
                Text("\(Int(sz.width)) × \(Int(sz.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    Task { await session.startCountdownThenBegin() }
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.counting || !session.canBeginArmed)

                Button("Cancel") {
                    Task { await session.cancelCountdownOrArming() }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    /// Armed-view header: interactive area nudges the user to adjust the box.
    private var armedHeader: String {
        if session.counting { return "Starting…" }
        return captureAreaEnabled ? "Adjust area, then record" : "Sources ready"
    }
```

- [ ] **Step 11: Build**

Run: `swift build`
Expected: PASS — the modal is gone and all consumers are rewired.

- [ ] **Step 12: Run the suite**

Run: `swift test`
Expected: PASS, 49 tests.

- [ ] **Step 13: Commit Tasks 2–4 together (after user confirmation)**

```bash
git add Sources/CaptureStudio/App/AreaControlBar.swift \
        Sources/CaptureStudio/App/AreaSelector.swift \
        Sources/CaptureStudio/Recorder/RecordingSession.swift \
        Sources/CaptureStudio/App/RecorderMenuView.swift
git commit -m "Merge area selection into the live preview flow

Area mode now opens one Preview / Select Area button: the selection
overlay stays editable while the camera preview shows, and recording
starts from the tray or Return. The screen recorder is built from the
final selection at record time. ESC cancels; no confirm button in the bar.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: On-device verification

Code can't prove the panel z-order, mouse routing, or capture-exclusion behavior — only a running app can. This task is the manual gate.

**Files:** none (verification only).

- [ ] **Step 1: Build and relaunch the app**

```bash
scripts/build-app.sh debug
pkill -x CaptureStudio; open dist/CaptureStudio.app
```

- [ ] **Step 2: Walk the checklist** (note pass/fail for each; any fail → `superpowers:systematic-debugging`)

1. **First run / nil region:** with no saved area, Area tab → "Preview / Select Area". Overlay opens empty; bar shows "Drag to select"; tray **Record** is disabled; Return does nothing. Drag a box → Record enables, armed view shows the live size.
2. **Live edit:** move / resize / change aspect ratio. Tray size updates live; aspect templates still constrain the box.
3. **Multi-display follow:** drag a selection onto a different screen. The new screen's box becomes active, the old one clears, and the **camera preview stays where it was**.
4. **Camera on:** with a camera selected, the preview panel is visible above the dim and does **not** block dragging elsewhere; the aspect bar sits on top and its chips are clickable.
5. **Start from tray:** click **Record** → countdown centers on the region → recording starts. Open the result: `screen.mp4` shows the region only, with **no overlay/dim/handles/aspect-bar** baked in.
6. **Start with Return:** repeat but press **Return / Enter** instead of the tray button — same result.
7. **Esc cancel:** open preview, press **Esc** → back to idle, camera preview closes, and no empty `.capturestudio` bundle is left in the recordings folder.
8. **Camera off (screen-only area):** Area tab with no camera → "Preview / Select Area" still opens the interactive overlay (not a direct record), and Record/Return work.
9. **Hotkey unchanged:** trigger the global hotkey in Area mode → it uses the **saved** region (no interactive overlay), exactly as before.
10. **Full-display unaffected:** switch to Full Display → button reads "Preview", picker governs the display, flow is unchanged.

- [ ] **Step 3: Confirm the saved region round-trips**

After a successful interactive record, reopen the menu: the Area readout shows the just-used `display · W×H`, and the next "Preview / Select Area" seeds that box.

---

## Self-review (author checklist — completed)

**Spec coverage:**
- Overlay refactor (spec §A) → Task 3. Control bar (spec §B) → Task 2. Tray menu (spec §C) → Task 4 Steps 8–10. Session/deferred recorder (spec §D) → Task 4 Steps 1–7. Hotkey unchanged (spec §E) → Task 4 Step 7 note + Task 5 check 9. Risks (spec) → Task 5 checks 4, 5, 7. Testing (spec) → Task 1 (pure helper) + Task 5 (manual).
- Locked copy present: bar hint (Task 2 Step 2), armed header (Task 4 Step 10).

**Placeholder scan:** none — every code step carries full code; no "TBD"/"handle edge cases"/"similar to".

**Type consistency:** `isValid` (Task 1) used identically in Tasks 2/3. `AreaSelectionOverlay` API (`present(initialRegion:initialDisplayID:)`, `dismiss()`, `onChange`/`onCancel`/`onStart`) defined in Task 3 and consumed in Task 4. `canBeginArmed` / `armedAreaSize` defined in Task 4 Step 1 and read in Steps 9–10. `ScreenRecorder(display:item:outputURL:systemAudioURL:region:)` and `RegionOutlineOverlay(region:onDisplay:)` match existing call sites.

**Compile coupling:** Tasks 2–4 deliberately share one green-build boundary (the modal is deleted and its consumers rewired); they commit together in Task 4 Step 13. Task 1 is independent and commits on its own.
