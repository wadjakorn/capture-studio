import AppKit
import SwiftUI

/// Drag-to-select overlay (macOS-screenshot style). Dims **every** screen at once
/// with a single overlay session; the user drags a rectangle on whichever screen
/// they like. Unlike a one-shot screenshot, the selection **persists** after the
/// drag: it can be moved, resized from eight handles, redrawn by dragging on empty
/// space, or constrained to an aspect-ratio template. The screen the selection
/// lands on **is** the capture display — derived from the drag, not chosen
/// separately. Confirm with Return or the **Use Area** button; ESC / Cancel aborts.
/// Returns the selection in **display-local points** (top-left origin within that
/// display) together with its display id.
@MainActor
enum AreaSelector {
    /// Minimum selection size (points); a smaller drag is treated as a non-commit
    /// so a stray click never produces a 1px region.
    static let minSize: CGFloat = 20

    /// The single in-flight session, if any. A new `selectRegion` call dismisses
    /// it first, so the dim overlay can never stack.
    private static var active: Coordinator?

    static func selectRegion() async -> (region: CGRect, displayID: CGDirectDisplayID)? {
        // Guarantee a single overlay: tear down any session still on screen.
        active?.cancel()
        active = nil

        let priorApp = NSWorkspace.shared.frontmostApplication

        return await withCheckedContinuation { continuation in
            let coordinator = Coordinator(continuation: continuation, priorApp: priorApp)
            active = coordinator
            coordinator.present(minSize: minSize)
        }
    }

    /// In-flight drag, owned by the Coordinator.
    private enum DragMode {
        case draw(anchor: CGPoint)
        case move(last: CGPoint)
        case resize(Handle)
    }

    /// Owns every screen's dim panel, the control bar, the edit state, and the
    /// continuation — resolving exactly once. Also installs a shared key monitor
    /// (only one panel can be key, so per-view key handling alone wouldn't catch
    /// Return/ESC on the others).
    @MainActor
    final class Coordinator {
        private var panels: [(panel: NSPanel, view: SelectionView, screen: NSScreen)] = []
        private var controlPanel: NSPanel?
        private let model = AreaControlModel()
        private var continuation: CheckedContinuation<(region: CGRect, displayID: CGDirectDisplayID)?, Never>?
        private let priorApp: NSRunningApplication?
        private var keyMonitor: Any?
        private var minSize: CGFloat = 20

        /// The committed selection (display-local top-left points) and the screen
        /// it lives on. `nil` until the first qualifying drag.
        private var state: RegionEditState?
        private var activeScreen: NSScreen?
        /// Aspect applied to new draws / resizes; mirrors the control bar choice.
        private var aspect: AspectRatio = .free
        private var dragMode: DragMode?
        /// Snapshot before a redraw, restored if the new drag is too small.
        private var preDrawState: RegionEditState?
        private var preDrawScreen: NSScreen?

        private let handleRadius: CGFloat = 9

        init(continuation: CheckedContinuation<(region: CGRect, displayID: CGDirectDisplayID)?, Never>,
             priorApp: NSRunningApplication?) {
            self.continuation = continuation
            self.priorApp = priorApp
        }

        // MARK: Presentation

        func present(minSize: CGFloat) {
            self.minSize = minSize

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
            model.onConfirm = { [weak self] in self?.confirm() }
            model.onCancel = { [weak self] in self?.cancel() }
            presentControlBar(on: NSScreen.main ?? NSScreen.screens.first)
            refreshControlBar()

            // Return confirms, ESC cancels — regardless of which panel is key.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                switch event.keyCode {
                case 53:            // Escape
                    self?.cancel(); return nil
                case 36, 76:        // Return, keypad Enter
                    self?.confirm(); return nil
                default:
                    return event
                }
            }

            NSApp.activate(ignoringOtherApps: true)
            panels.first?.panel.makeKey()
        }

        private func presentControlBar(on screen: NSScreen?) {
            let host = NSHostingView(rootView: AreaControlBar(model: model))
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize

            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            // One level above the dim panels so it sits on top and receives clicks
            // (same level → unreliable z-order, dim overlay swallows the mouse).
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
        }

        func pointerUp() {
            // A redraw that never reached the minimum size restores the prior
            // selection (so a stray click doesn't wipe a good region).
            if case .draw = dragMode, let s = state,
               s.rect.width < minSize || s.rect.height < minSize {
                state = preDrawState
                activeScreen = preDrawScreen ?? activeScreen
            }
            dragMode = nil
            preDrawState = nil
            preDrawScreen = nil
            redrawAll()
            refreshControlBar()
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
        }

        // MARK: Refresh

        private func redrawAll() {
            for entry in panels { entry.view.needsDisplay = true }
        }

        private func refreshControlBar() {
            model.aspect = aspect
            if let r = state?.rect, r.width >= minSize, r.height >= minSize {
                model.sizeText = "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))"
                model.canConfirm = true
            } else {
                model.sizeText = ""
                model.canConfirm = false
            }
        }

        // MARK: Resolution

        func confirm() {
            guard let state, let screen = activeScreen,
                  state.rect.width >= minSize, state.rect.height >= minSize,
                  let displayID = screen.displayID else { return }
            // state.rect is already display-local top-left points (the struct's
            // coordinate space matches the screen's), so no flip is needed.
            finish((region: state.rect, displayID: displayID))
        }

        func cancel() { finish(nil) }

        /// Resolve once: tear down everything, restore focus, resume the result.
        private func finish(_ result: (region: CGRect, displayID: CGDirectDisplayID)?) {
            guard continuation != nil else { return }
            teardown()
            priorApp?.activate()
            continuation?.resume(returning: result)
            continuation = nil
            if AreaSelector.active === self { AreaSelector.active = nil }
        }

        private func teardown() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            for entry in panels { entry.panel.orderOut(nil) }
            panels.removeAll()
            controlPanel?.orderOut(nil)
            controlPanel = nil
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Renders the dim backdrop + the (optional) selection rect with eight handles and
/// a W×H readout, and forwards mouse gestures to the Coordinator in screen-local,
/// top-left, y-down points. Holds no selection state of its own.
final class SelectionView: NSView {
    weak var coordinator: AreaSelector.Coordinator?
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

    override func rightMouseDown(with event: NSEvent) { coordinator?.cancel() }
    override func cancelOperation(_ sender: Any?) { coordinator?.cancel() }

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
