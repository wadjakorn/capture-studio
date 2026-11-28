import Foundation
import AppKit
import CoreGraphics
import os

/// One on-screen window as the window server lists it. Frame in global screen
/// points, top-left origin.
struct WindowCandidate: Equatable, Sendable {
    var id: Int
    var pid: Int32
    var layer: Int
    var alpha: Double
    var frame: CGRect
}

/// Which window the pointer is over. Pure — unit-tested.
enum ActiveWindow {
    /// Smaller than this (points, either side) is not a window worth framing.
    static let minSide = 50.0

    /// `candidates` front to back. The first ordinary (layer 0), visible window
    /// of a useful size that contains `pointer` and touches the captured
    /// rectangle. One of our own windows counts only when it is a registered
    /// content window — the rest is recording chrome and is not in the video.
    static func pick(_ candidates: [WindowCandidate], pointer: CGPoint, captured: CGRect,
                     ownPID: Int32, contentIDs: Set<Int>) -> WindowCandidate? {
        for c in candidates {
            guard c.layer == 0, c.alpha > 0,
                  Double(c.frame.width) >= minSide, Double(c.frame.height) >= minSide,
                  c.frame.contains(pointer) else { continue }
            if c.pid == ownPID && !contentIDs.contains(c.id) { continue }
            // The topmost window under the pointer decides; one outside the
            // captured area is "no window" rather than a look further down.
            return c.frame.intersects(captured) ? c : nil
        }
        return nil
    }
}

/// Keeps a line only when the window or its frame changed. Pure — unit-tested.
struct WindowLog {
    struct Entry: Equatable {
        var hostTime: Double
        var line: WindowLine // t filled in at write time
    }

    private(set) var entries: [Entry] = []

    mutating func note(hostTime: Double, window: WindowCandidate?) {
        let line = window.map {
            WindowLine(t: 0, id: $0.id, x: Double($0.frame.minX), y: Double($0.frame.minY),
                       w: Double($0.frame.width), h: Double($0.frame.height))
        } ?? .none(t: 0)
        if let last = entries.last?.line, last.id == line.id,
           abs(last.x - line.x) < 1, abs(last.y - line.y) < 1,
           abs(last.w - line.w) < 1, abs(last.h - line.h) < 1 { return }
        entries.append(Entry(hostTime: hostTime, line: line))
    }

    /// Lines with `t` relative to `anchorHostTime`.
    func lines(anchorHostTime: Double) -> [WindowLine] {
        entries.map {
            var line = $0.line
            line.t = (($0.hostTime - anchorHostTime) * 10_000).rounded() / 10_000
            return line
        }
    }
}

/// Records which window the pointer is over during a recording (10 Hz, plus
/// shortly after every mouse-down), for the editor's follow camera. Only window
/// number, layer, alpha, owner pid and bounds are read — never a title. Needs
/// no permission beyond Screen Recording. Best-effort: any failure is "no
/// window data", never a failed recording.
///
/// The window-list call runs on a background queue so the main thread — and
/// the 60 Hz pointer sampler on it — never waits for the window server.
@MainActor
final class WindowTracker {
    private struct State {
        var log = WindowLog()
        var busy = false
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "dev.wadjakorn.capture-studio.window-tracker",
                                      qos: .utility)
    private var timer: Timer?
    private var monitors: [Any] = []
    private var captured = CGRect.zero
    private var primaryScreenHeight = 0.0
    private(set) var isTracking = false

    /// `captured`: the recorded rectangle in global screen points, top-left
    /// origin (`DisplayInfo` origin + point size).
    func start(captured: CGRect) {
        guard !isTracking else { return }
        isTracking = true
        self.captured = captured
        primaryScreenHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        state.withLock { $0.log = WindowLog(); $0.busy = false; $0.generation += 1 }

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // A click usually changes what is in front; look again once it has.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let handler: (NSEvent) -> Void = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                MainActor.assumeIsolated { self?.sample() }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
        sample()
    }

    /// Stops tracking and writes windows.jsonl. Nothing is written when
    /// nothing was seen.
    func stopAndWrite(to url: URL, screenAnchorHostTime: Double) throws {
        guard isTracking else { return }
        let log = halt()
        let lines = log.lines(anchorHostTime: screenAnchorHostTime)
        guard !lines.isEmpty else { return }
        try WindowsCodec.encodeLines(lines).write(to: url, options: .atomic)
    }

    func cancel() {
        _ = halt()
    }

    private func halt() -> WindowLog {
        isTracking = false
        timer?.invalidate()
        timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        // A sample still in flight belongs to the old generation and is dropped.
        return state.withLock { s in
            let log = s.log
            s.log = WindowLog()
            s.generation += 1
            return log
        }
    }

    private func sample() {
        guard isTracking else { return }
        let generation: Int? = state.withLock { s in
            guard !s.busy else { return nil }
            s.busy = true
            return s.generation
        }
        guard let generation else { return }

        let mouse = NSEvent.mouseLocation
        let pointer = CGPoint(x: Double(mouse.x), y: primaryScreenHeight - Double(mouse.y))
        let captured = self.captured
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let contentIDs = Set(CaptureContentWindows.shared.snapshot
            .filter { $0.isVisible }
            .flatMap { [$0.windowNumber] + $0.sheetNumbers })
        let hostTime = EventTracker.nowHostTime()
        let state = self.state

        queue.async {
            let window = ActiveWindow.pick(Self.onScreenWindows(), pointer: pointer,
                                           captured: captured, ownPID: ownPID,
                                           contentIDs: contentIDs)
            state.withLock { s in
                s.busy = false
                guard s.generation == generation else { return }
                s.log.note(hostTime: hostTime, window: window)
            }
        }
    }

    /// On-screen windows front to back. Reads geometry and ownership only.
    private nonisolated static func onScreenWindows() -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            return WindowCandidate(id: id, pid: pid, layer: layer, alpha: alpha, frame: frame)
        }
    }
}
