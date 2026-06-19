import CoreGraphics

/// A named aspect-ratio constraint for the area selector. `value` is width/height;
/// `nil` means freeform (no constraint).
struct AspectRatio: Equatable {
    let label: String
    let value: CGFloat?
    /// Starting selection size (points) when this ratio is picked. Explicit (not
    /// `value * reference`) so it lands on exact, clean dimensions. `nil` = free.
    let defaultSize: CGSize?

    static let free = AspectRatio(label: "Free", value: nil, defaultSize: nil)
    static let r16x9 = AspectRatio(label: "16:9", value: 16.0 / 9.0, defaultSize: CGSize(width: 1280, height: 720))
    static let r9x16 = AspectRatio(label: "9:16", value: 9.0 / 16.0, defaultSize: CGSize(width: 405, height: 720))
    static let r1x1 = AspectRatio(label: "1:1", value: 1.0, defaultSize: CGSize(width: 720, height: 720))
    static let r4x5 = AspectRatio(label: "4:5", value: 4.0 / 5.0, defaultSize: CGSize(width: 576, height: 720))
    static let r4x3 = AspectRatio(label: "4:3", value: 4.0 / 3.0, defaultSize: CGSize(width: 960, height: 720))

    /// Order shown as chips in the control bar.
    static let all: [AspectRatio] = [.free, .r16x9, .r9x16, .r1x1, .r4x5, .r4x3]
}

/// A resize grip on the selection rectangle (8 compass points).
enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// Result of hit-testing a point against the selection.
enum Hit: Equatable {
    case handle(Handle)
    case move
}

/// Pure geometry model for the editable area-selection overlay. All coordinates
/// are top-left origin, y-down, within `bounds` (the screen size in points). The
/// AppKit view forwards gestures into these mutating ops and renders `rect`.
struct RegionEditState {
    var bounds: CGSize
    var rect: CGRect
    var aspect: AspectRatio = .free
    var minSize: CGFloat = 20

    /// True once the selection is at least `minSize` in both dimensions — the
    /// threshold for committing it (drives the control bar and Start Record).
    var isValid: Bool { rect.width >= minSize && rect.height >= minSize }

    // MARK: Draw

    /// Replace the selection with a fresh drag from `anchor` to `point`. With an
    /// aspect lock the width drives the height (pointer y only sets direction).
    mutating func drawFrom(_ anchor: CGPoint, to point: CGPoint) {
        if let ratio = aspect.value {
            let w = abs(point.x - anchor.x)
            let h = w / ratio
            let x = point.x >= anchor.x ? anchor.x : anchor.x - w
            let y = point.y >= anchor.y ? anchor.y : anchor.y - h
            rect = CGRect(x: x, y: y, width: w, height: h)
        } else {
            rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                          width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        }
    }

    // MARK: Move

    /// Translate the whole rect by `delta`, clamped so it stays inside `bounds`.
    mutating func move(by delta: CGSize) {
        var r = rect.offsetBy(dx: delta.width, dy: delta.height)
        r.origin.x = clamp(r.origin.x, 0, max(0, bounds.width - r.width))
        r.origin.y = clamp(r.origin.y, 0, max(0, bounds.height - r.height))
        rect = r
    }

    // MARK: Resize

    /// Drag `handle` toward `point`. The opposite edge/corner stays fixed; the
    /// result is clamped to `bounds` and floored at `minSize`. With an aspect
    /// lock the constrained dimension follows the dragged one.
    mutating func resize(_ handle: Handle, to point: CGPoint) {
        let p = CGPoint(x: clamp(point.x, 0, bounds.width),
                        y: clamp(point.y, 0, bounds.height))
        if let ratio = aspect.value {
            rect = aspectResize(handle, to: p, ratio: ratio)
        } else {
            rect = freeResize(handle, to: p)
        }
    }

    private func freeResize(_ handle: Handle, to p: CGPoint) -> CGRect {
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if handle.movesLeft { left = min(p.x, right - minSize) }
        if handle.movesRight { right = max(p.x, left + minSize) }
        if handle.movesTop { top = min(p.y, bottom - minSize) }
        if handle.movesBottom { bottom = max(p.y, top + minSize) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func aspectResize(_ handle: Handle, to p: CGPoint, ratio: CGFloat) -> CGRect {
        switch handle {
        case .topLeft:
            return cornerAspect(fixed: CGPoint(x: rect.maxX, y: rect.maxY), toward: p, ratio: ratio)
        case .topRight:
            return cornerAspect(fixed: CGPoint(x: rect.minX, y: rect.maxY), toward: p, ratio: ratio)
        case .bottomLeft:
            return cornerAspect(fixed: CGPoint(x: rect.maxX, y: rect.minY), toward: p, ratio: ratio)
        case .bottomRight:
            return cornerAspect(fixed: CGPoint(x: rect.minX, y: rect.minY), toward: p, ratio: ratio)
        case .left, .right:
            return sideAspectHorizontal(handle, to: p, ratio: ratio)
        case .top, .bottom:
            return sideAspectVertical(handle, to: p, ratio: ratio)
        }
    }

    /// Resize from a free corner toward `toward`, keeping `fixed` pinned and the
    /// ratio locked (width drives height). Shrinks to fit `bounds` if needed.
    private func cornerAspect(fixed: CGPoint, toward: CGPoint, ratio: CGFloat) -> CGRect {
        let sx: CGFloat = toward.x >= fixed.x ? 1 : -1
        let sy: CGFloat = toward.y >= fixed.y ? 1 : -1
        var w = max(minSize, abs(toward.x - fixed.x))
        var h = w / ratio
        let availX = sx > 0 ? bounds.width - fixed.x : fixed.x
        let availY = sy > 0 ? bounds.height - fixed.y : fixed.y
        if w > availX { w = availX; h = w / ratio }
        if h > availY { h = availY; w = h * ratio }
        w = max(minSize, w)
        h = max(minSize, h)
        let mx = fixed.x + sx * w
        let my = fixed.y + sy * h
        return CGRect(x: min(fixed.x, mx), y: min(fixed.y, my), width: w, height: h)
    }

    /// Left/right edge drag with ratio lock: width from the dragged edge, height
    /// centered on the rect's vertical center.
    private func sideAspectHorizontal(_ handle: Handle, to p: CGPoint, ratio: CGFloat) -> CGRect {
        var left = rect.minX, right = rect.maxX
        if handle == .left { left = min(p.x, right - minSize) } else { right = max(p.x, left + minSize) }
        var w = right - left
        var h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        let cy = rect.midY
        let top = clamp(cy - h / 2, 0, bounds.height - h)
        let x = (handle == .left) ? right - w : left
        return CGRect(x: clamp(x, 0, bounds.width - w), y: top, width: w, height: h)
    }

    /// Top/bottom edge drag with ratio lock: height from the dragged edge, width
    /// centered on the rect's horizontal center.
    private func sideAspectVertical(_ handle: Handle, to p: CGPoint, ratio: CGFloat) -> CGRect {
        var top = rect.minY, bottom = rect.maxY
        if handle == .top { top = min(p.y, bottom - minSize) } else { bottom = max(p.y, top + minSize) }
        var h = bottom - top
        var w = h * ratio
        if w > bounds.width { w = bounds.width; h = w / ratio }
        let cx = rect.midX
        let left = clamp(cx - w / 2, 0, bounds.width - w)
        let y = (handle == .top) ? bottom - h : top
        return CGRect(x: left, y: clamp(y, 0, bounds.height - h), width: w, height: h)
    }

    // MARK: Aspect

    /// Adopt `aspect` and place its **default-sized** rect, centered on the
    /// current rect's center and scaled down to fit `bounds` (90%) if needed.
    /// Picking a ratio sets a clean starting size rather than shrinking whatever
    /// was there. `.free` records the choice but leaves the rect untouched.
    mutating func applyAspect(_ aspect: AspectRatio) {
        self.aspect = aspect
        guard let ratio = aspect.value, let def = aspect.defaultSize else { return }
        let cx = rect.midX, cy = rect.midY
        var w = def.width, h = def.height
        let maxW = bounds.width * 0.9, maxH = bounds.height * 0.9
        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }
        let x = clamp(cx - w / 2, 0, bounds.width - w)
        let y = clamp(cy - h / 2, 0, bounds.height - h)
        rect = CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Hit test

    /// What's under `point`: a resize handle within `handleRadius`, `.move` if
    /// inside the rect, or `nil` (outside → start a fresh draw).
    func hitTest(_ point: CGPoint, handleRadius: CGFloat) -> Hit? {
        for handle in Handle.allCases {
            let c = handlePoint(handle)
            if abs(point.x - c.x) <= handleRadius && abs(point.y - c.y) <= handleRadius {
                return .handle(handle)
            }
        }
        return rect.contains(point) ? .move : nil
    }

    /// Screen-space center of a handle's grip.
    func handlePoint(_ handle: Handle) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    hi < lo ? lo : min(max(v, lo), hi)
}

private extension Handle {
    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}
