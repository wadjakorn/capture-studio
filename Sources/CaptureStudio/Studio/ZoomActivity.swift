import Foundation
import CoreGraphics

/// A closed time range on the timeline, in seconds.
struct TimeSpan: Equatable {
    var begin: Double
    var end: Double
    var length: Double { end - begin }
}

/// What the user was doing during a recording, extracted from `events.jsonl`:
/// the signals auto zoom uses to decide when to be zoomed in. Pure — no
/// AVFoundation / AppKit deps — and unit-tested.
struct ZoomActivity: Equatable {
    /// Mouse-downs inside the captured source that were not the start of a drag.
    var clicks: [ClickSample] = []
    /// Press-move-release gestures (selections, drags).
    var drags: [TimeSpan] = []
    /// Bursts of typing. Only key timestamps and modifiers are read — never which
    /// keys. Empty when Input Monitoring was not granted at record time.
    var typing: [TimeSpan] = []
    /// Bursts of scrolling.
    var scrolls: [TimeSpan] = []

    /// A drag must travel more than this fraction of the source width.
    static let dragMinTravelFrac = 0.01
    /// Keys closer than this (seconds) belong to one typing burst.
    static let keyGap = 1.0
    /// A typing burst needs at least this many keys.
    static let minKeys = 3
    /// Scroll events closer than this (seconds) belong to one burst.
    static let scrollGap = 0.3

    /// Nothing worth zooming in on (scrolling alone does not count).
    var isEmpty: Bool { clicks.isEmpty && drags.isEmpty && typing.isEmpty }

    static func from(events: [EventLine], display: DisplayInfo,
                     sourceSize: CGSize) -> ZoomActivity {
        var out = ZoomActivity()
        let bounds = CGRect(origin: .zero, size: sourceSize)
        let minTravel = dragMinTravelFrac * Double(sourceSize.width)
        func point(_ e: EventLine) -> CGPoint? {
            guard let x = e.x, let y = e.y else { return nil }
            return CursorOverlay.sourcePoint(x: x, y: y, display: display, sourceSize: sourceSize)
        }

        var pendingDown: (t: Double, p: CGPoint)?
        func flushAsClick() {
            if let d = pendingDown, bounds.contains(d.p) {
                out.clicks.append(ClickSample(t: d.t, p: d.p))
            }
            pendingDown = nil
        }
        var keyTimes: [Double] = []
        var scrollTimes: [Double] = []

        for e in events.sorted(by: { $0.t < $1.t }) {
            switch e.e {
            case .down:
                flushAsClick()
                if let p = point(e) { pendingDown = (e.t, p) }
            case .up:
                guard let d = pendingDown, let p = point(e) else { flushAsClick(); continue }
                let travel = hypot(Double(p.x - d.p.x), Double(p.y - d.p.y))
                if travel > minTravel {
                    if bounds.contains(d.p) || bounds.contains(p) {
                        out.drags.append(TimeSpan(begin: d.t, end: e.t))
                    }
                    pendingDown = nil
                } else {
                    flushAsClick()
                }
            case .key:
                // Shortcuts are not typing. The pointer position on a key event
                // is irrelevant, so it is not bounds-checked.
                let mods = e.mods ?? []
                if !mods.contains("cmd") && !mods.contains("ctrl") { keyTimes.append(e.t) }
            case .scroll:
                scrollTimes.append(e.t)
            case .pos:
                break
            }
        }
        flushAsClick()

        out.typing = bursts(keyTimes, gap: keyGap).filter { $0.count >= minKeys }.map(\.span)
        out.scrolls = bursts(scrollTimes, gap: scrollGap).map(\.span)
        return out
    }

    /// Drop everything that starts after `duration` (events can outlast the video).
    func trimmed(to duration: Double) -> ZoomActivity {
        let limit = duration + 0.001
        return ZoomActivity(clicks: clicks.filter { $0.t <= limit },
                            drags: drags.filter { $0.begin <= limit },
                            typing: typing.filter { $0.begin <= limit },
                            scrolls: scrolls.filter { $0.begin <= limit })
    }

    /// Group sorted times into runs whose neighbours are at most `gap` apart.
    private static func bursts(_ times: [Double], gap: Double) -> [(span: TimeSpan, count: Int)] {
        var out: [(span: TimeSpan, count: Int)] = []
        for t in times {
            if let last = out.last, t - last.span.end <= gap {
                out[out.count - 1] = (TimeSpan(begin: last.span.begin, end: t), last.count + 1)
            } else {
                out.append((TimeSpan(begin: t, end: t), 1))
            }
        }
        return out
    }
}
