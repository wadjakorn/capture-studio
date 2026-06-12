import Foundation
import AppKit
import CoreMedia

/// Captures cursor positions (fixed 60Hz sampling — NOT coalesced mouseMoved
/// events, fixed-rate samples are what smoothing interpolation needs later),
/// clicks, scrolls, and key presses. Timestamps are host-clock seconds,
/// converted to screen-relative `t` when written at stop.
///
/// Events are held in memory (~few MB/hour) and written once at finalize.
@MainActor
final class EventTracker {
    private struct RawEvent {
        var hostTime: Double
        var line: EventLine // t filled in at write time
    }

    private var events: [RawEvent] = []
    private var monitors: [Any] = []
    private var samplerTimer: Timer?
    private(set) var isTracking = false

    /// Primary screen height for Cocoa (bottom-left) → CG (top-left) Y flip.
    private var primaryScreenHeight: Double = Double(NSScreen.screens.first?.frame.height ?? 0)

    static func nowHostTime() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    func start() {
        guard !isTracking else { return }
        isTracking = true
        events.removeAll()
        primaryScreenHeight = Double(NSScreen.screens.first?.frame.height ?? 0)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleCursor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        samplerTimer = timer

        addMonitor(for: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.append(.down, from: event, btn: Self.buttonName(event))
        }
        addMonitor(for: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { [weak self] event in
            self?.append(.up, from: event, btn: Self.buttonName(event))
        }
        addMonitor(for: [.scrollWheel]) { [weak self] event in
            self?.append(.scroll, from: event, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        }
        // Fires only if Input Monitoring permission is granted; otherwise the
        // monitor is silently inert — recording proceeds without key data.
        addMonitor(for: [.keyDown]) { [weak self] event in
            self?.append(.key, from: event, keyCode: Int(event.keyCode), mods: Self.modNames(event.modifierFlags))
        }
    }

    /// Stops tracking and writes events.jsonl with t relative to the screen
    /// track's session start.
    func stopAndWrite(to url: URL, screenAnchorHostTime: Double) throws {
        guard isTracking else { return }
        isTracking = false
        samplerTimer?.invalidate()
        samplerTimer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()

        var lines: [EventLine] = []
        lines.reserveCapacity(events.count)
        for raw in events {
            var line = raw.line
            line.t = (raw.hostTime - screenAnchorHostTime).rounded(toPlaces: 4)
            lines.append(line)
        }
        events.removeAll()
        try EventsCodec.encodeLines(lines).write(to: url, options: .atomic)
    }

    func cancel() {
        isTracking = false
        samplerTimer?.invalidate()
        samplerTimer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        events.removeAll()
    }

    // MARK: - Capture

    private func addMonitor(for mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        // Global monitor covers other apps; local covers our own UI.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(event)
            return event
        }
        if let local { monitors.append(local) }
    }

    private func sampleCursor() {
        guard isTracking else { return }
        let location = cgPoint(fromCocoa: NSEvent.mouseLocation)
        events.append(RawEvent(
            hostTime: Self.nowHostTime(),
            line: EventLine(t: 0, e: .pos, x: location.x, y: location.y, cursor: Self.cursorName())
        ))
    }

    private func append(_ kind: EventLine.Kind, from event: NSEvent,
                        btn: String? = nil, dx: Double? = nil, dy: Double? = nil,
                        keyCode: Int? = nil, mods: [String]? = nil) {
        guard isTracking else { return }
        let location = cgPoint(fromCocoa: NSEvent.mouseLocation)
        events.append(RawEvent(
            hostTime: Self.nowHostTime(),
            line: EventLine(t: 0, e: kind, x: location.x, y: location.y,
                            btn: btn, dx: dx, dy: dy, keyCode: keyCode, mods: mods)
        ))
    }

    // MARK: - Helpers

    /// Cocoa global coords are bottom-left origin; CG (and DisplayInfo) are top-left.
    private func cgPoint(fromCocoa point: NSPoint) -> (x: Double, y: Double) {
        (Double(point.x), primaryScreenHeight - Double(point.y))
    }

    private static func buttonName(_ event: NSEvent) -> String {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: return "left"
        case .rightMouseDown, .rightMouseUp: return "right"
        default: return "other"
        }
    }

    private static func modNames(_ flags: NSEvent.ModifierFlags) -> [String]? {
        var names: [String] = []
        if flags.contains(.command) { names.append("cmd") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.option) { names.append("opt") }
        if flags.contains(.control) { names.append("ctrl") }
        return names.isEmpty ? nil : names
    }

    private static func cursorName() -> String {
        guard let current = NSCursor.currentSystem else { return "unknown" }
        let known: [(NSCursor, String)] = [
            (.arrow, "arrow"), (.iBeam, "ibeam"), (.pointingHand, "pointingHand"),
            (.crosshair, "crosshair"), (.closedHand, "closedHand"), (.openHand, "openHand"),
            (.resizeLeftRight, "resizeLeftRight"), (.resizeUpDown, "resizeUpDown"),
        ]
        for (cursor, name) in known where current == cursor { return name }
        return "other"
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
