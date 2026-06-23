import SwiftUI

/// The subtitle track: a read-only strip showing imported `.srt` cues on the
/// shared time axis. Cues can't be retimed or text-edited (the `.srt` is the
/// source of truth) — tapping a cue seeks to it and selects the track for
/// styling. Cues rarely overlap; when they do the lane packs them into sub-rows
/// via `SubtitleTimeline.subRows`. A loader covers the lane while the track is
/// being applied or removed.
struct SubtitleTimelineLane: View {
    @ObservedObject var model: StudioModel

    private let rowHeight: CGFloat = 22
    private let rowSpacing: CGFloat = 3
    private let maxVisibleRows = 3
    private let laneSpace = "subtitleLane"

    private var cues: [SubtitleCue] { model.effectiveSubtitleCues }
    private var rows: [[SubtitleCue]] { SubtitleTimeline.subRows(cues) }

    private var contentHeight: CGFloat {
        let n = max(1, rows.count)
        return CGFloat(n) * rowHeight + CGFloat(max(0, n - 1)) * rowSpacing
    }
    private var visibleHeight: CGFloat {
        let n = min(max(1, rows.count), maxVisibleRows)
        return CGFloat(n) * rowHeight + CGFloat(max(0, n - 1)) * rowSpacing
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ScrollView(.vertical, showsIndicators: rows.count > maxVisibleRows) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(height: contentHeight)

                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowCues in
                        ForEach(rowCues) { cue in
                            cueView(cue, width: width)
                                .offset(y: CGFloat(rowIndex) * (rowHeight + rowSpacing))
                        }
                    }

                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: contentHeight)
                        .offset(x: fraction(model.currentTime) * width - 1)
                        .allowsHitTesting(false)
                }
                .frame(height: contentHeight)
                .coordinateSpace(name: laneSpace)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
                        .onChanged { value in
                            model.seek(to: time(atX: value.location.x, width: width))
                        }
                        .onEnded { value in
                            if abs(value.translation.width) < 3
                                && abs(value.translation.height) < 3 {
                                model.deselectAll()
                            }
                        }
                )
                .overlay { if model.subtitleState != .idle { loader } }
            }
            .frame(height: visibleHeight)
        }
        .frame(height: visibleHeight)
    }

    private var loader: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.thinMaterial)
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func cueView(_ cue: SubtitleCue, width: CGFloat) -> some View {
        let x0 = fraction(cue.begin) * width
        let x1 = fraction(cue.end) * width
        let selected = model.subtitleSelected
        let accent = Color.accentColor
        let bodyW = max(2, x1 - x0)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent.opacity(selected ? 0.45 : 0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? accent : .clear, lineWidth: 1.5)
                )
                .frame(width: bodyW, height: rowHeight - 2)

            Text(cue.text.isEmpty ? "—" : cue.text)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .frame(width: bodyW, height: rowHeight - 2, alignment: .leading)
                .allowsHitTesting(false)
        }
        .frame(width: bodyW, height: rowHeight, alignment: .leading)
        .offset(x: x0)
        .contentShape(Rectangle())
        .onTapGesture { select(cue) }
    }

    /// Select the track and seek into the cue's span (frame-aligned so it shows
    /// at the seeked frame).
    private func select(_ cue: SubtitleCue) {
        model.selectSubtitles(true)
        let aligned = TextTimeline.firstVisibleTime(begin: cue.begin,
                                                    fps: StudioModel.compositionFrameRate)
        model.seek(to: min(aligned < cue.end ? aligned : cue.begin, model.duration))
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(min(max(0, seconds / model.duration), 1))
    }
    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1)) * model.duration
    }
}
