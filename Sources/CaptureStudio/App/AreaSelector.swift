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
        // One level above the dim panels so it sits on top and receives clicks.
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

    /// The selection to draw on `screen`, or nil if the selection lives
    /// elsewhere (or doesn't exist yet).
    func selection(on screen: NSScreen) -> RegionEditState? {
        activeScreen === screen ? state : nil
    }

    func handleRadiusForDrawing() -> CGFloat { handleRadius }

    // MARK: Gesture forwarding (points are screen-local, top-left, y-down)

    func pointerDown(at point: CGPoint, on screen: NSScreen) {
        // Switching screens drops the old selection — a region can't span
        // displays, and the drag's screen is the capture display.
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
        // A redraw that never reached the minimum size restores the prior
        // selection (so a stray click doesn't wipe a good region).
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
            // No selection yet: materialize the ratio's default box centered on
            // the screen so the chip immediately shows something to adjust.
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

    /// Event location → screen-local top-left (y-down) point.
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

        // Selection rect: convert top-left y-down → view y-up.
        let r = state.rect
        let viewRect = NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)

        // Punch the selection clear so the user sees what they're capturing.
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
