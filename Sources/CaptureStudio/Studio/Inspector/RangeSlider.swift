import SwiftUI

/// Pure value math for `RangeSlider` — unit-tested.
enum RangeSliderMath {
    /// The value at horizontal position `x` on a track `width` wide, snapped
    /// to `step` and kept inside `bounds`.
    static func value(atX x: Double, width: Double, bounds: ClosedRange<Double>,
                      step: Double) -> Double {
        guard width > 0 else { return bounds.lowerBound }
        let f = min(max(x / width, 0), 1)
        let raw = bounds.lowerBound + f * (bounds.upperBound - bounds.lowerBound)
        let snapped = step > 0 ? (raw / step).rounded() * step : raw
        return min(max(snapped, bounds.lowerBound), bounds.upperBound)
    }

    /// Which end a press at `value` grabs: the nearer one; when both sit on the
    /// same spot, the one that can move toward the press — and at the top of
    /// the track, where only the lower one can move at all, the lower one.
    static func grabsLower(value: Double, lower: Double, upper: Double,
                           bounds: ClosedRange<Double>) -> Bool {
        let dl = abs(value - lower), du = abs(value - upper)
        if abs(dl - du) < 1e-9 { return value < lower || upper >= bounds.upperBound - 1e-9 }
        return dl < du
    }
}

/// One track with two thumbs: a lower and an upper bound. Dragging grabs the
/// nearer thumb; neither can pass the other. Keyboard and VoiceOver get two
/// ordinary sliders.
struct RangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let bounds: ClosedRange<Double>
    var step = 0.05
    var lowerLabel = "Least"
    var upperLabel = "Most"
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var draggingLower: Bool?
    private let thumb = 18.0

    var body: some View {
        GeometryReader { geo in
            let width = max(Double(geo.size.width) - thumb, 1)
            let span = bounds.upperBound - bounds.lowerBound
            let lx = span > 0 ? (lower - bounds.lowerBound) / span * width : 0
            let ux = span > 0 ? (upper - bounds.lowerBound) / span * width : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)
                    .padding(.horizontal, thumb / 2)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(ux - lx, 0), height: 4)
                    .offset(x: lx + thumb / 2)
                knob.offset(x: lx)
                knob.offset(x: ux)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let v = RangeSliderMath.value(atX: Double(g.location.x) - thumb / 2,
                                                      width: width, bounds: bounds, step: step)
                        if draggingLower == nil {
                            draggingLower = RangeSliderMath.grabsLower(
                                value: v, lower: lower, upper: upper, bounds: bounds)
                            onEditingChanged(true)
                        }
                        if draggingLower == true {
                            lower = min(v, upper)
                        } else {
                            upper = max(v, lower)
                        }
                    }
                    .onEnded { _ in
                        draggingLower = nil
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 22)
        .accessibilityRepresentation {
            VStack {
                Slider(value: Binding(get: { lower }, set: { lower = min($0, upper) }),
                       in: bounds, step: step, onEditingChanged: onEditingChanged) {
                    Text(lowerLabel)
                }
                Slider(value: Binding(get: { upper }, set: { upper = max($0, lower) }),
                       in: bounds, step: step, onEditingChanged: onEditingChanged) {
                    Text(upperLabel)
                }
            }
        }
    }

    private var knob: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .frame(width: thumb, height: thumb)
    }
}
