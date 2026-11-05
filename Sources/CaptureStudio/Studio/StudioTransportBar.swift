import SwiftUI

/// Bottom transport chrome: play/pause + timecode, split & cut controls, plus a
/// speed placeholder and a "timelines visible" label. Mirrors the bottom
/// bar's `transportControls`. Not yet wired into
/// `StudioView` — Task 5 swaps the layout to use this.
struct StudioTransportBar: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        HStack(spacing: 12) {
            transportControls
            Divider().frame(height: 16)
            cutControls
            Divider().frame(height: 16)
            zoomControls
            Spacer()
            Text("\(visibleTimelineCount) timelines visible")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var transportControls: some View {
        Button { model.togglePlay() } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
        }
        .keyboardShortcut(.space, modifiers: [])
        .help(model.isPlaying ? "Pause" : "Play")

        Text("\(timecode(model.currentTime)) / \(timecode(model.duration))")
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Split / cut controls for the master timeline, all non-destructive. Hovering
    /// a cut-type button previews its effect on the timeline (`hoverAction`).
    @ViewBuilder private var cutControls: some View {
        Button { model.splitAtPlayhead() } label: {
            Image(systemName: "square.split.2x1")
        }
        .disabled(!model.canSplitAtPlayhead)
        .help("Split the timeline at the playhead")

        Button {
            model.hoverAction = nil
            model.toggleCutAtPlayhead()
        } label: {
            Image(systemName: cutIsRestore ? "eye" : "eye.slash")
        }
        .disabled(!model.canToggleCutAtPlayhead)
        .help(cutIsRestore ? "Restore this segment" : "Cut this segment from the video")
        .onHover { model.hoverAction = $0 ? (cutIsRestore ? .restoreSegment : .cutSegment) : nil }

        Button {
            model.hoverAction = nil
            model.trimStartAtPlayhead()
        } label: { Text("Trim Start") }
            .disabled(!model.canTrimStartAtPlayhead)
            .help("Cut everything before the playhead")
            .onHover { model.hoverAction = $0 ? .trimStart : nil }

        Button {
            model.hoverAction = nil
            model.trimEndAtPlayhead()
        } label: { Text("Trim End") }
            .disabled(!model.canTrimEndAtPlayhead)
            .help("Cut everything after the playhead")
            .onHover { model.hoverAction = $0 ? .trimEnd : nil }

        Button {
            model.hoverAction = nil
            model.resetSegments()
        } label: { Image(systemName: "xmark.circle") }
            .disabled(!model.canResetSegments)
            .help("Clear all splits & cuts")
            .onHover { model.hoverAction = $0 ? .clearAll : nil }

        if model.hasCutSegments {
            Text("\(model.segments.filter(\.hidden).count) cut")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// True when the playhead sits on an already-hidden segment (so the toggle
    /// restores rather than cuts).
    private var cutIsRestore: Bool { model.segmentAtPlayhead?.hidden == true }

    /// Horizontal timeline zoom: a log-scaled slider (most travel over the
    /// common low zoom levels), a readout, and Fit-to-window.
    @ViewBuilder private var zoomControls: some View {
        Image(systemName: "minus.magnifyingglass")
            .font(.caption).foregroundStyle(.secondary)
        Slider(value: Binding(
            get: { TimelineScale.zoomSliderPosition(model.timelineZoom) },
            set: { model.setTimelineZoom(TimelineScale.zoomForSlider($0)) }),
               in: 0...1)
            .frame(width: 90)
            .controlSize(.mini)
            .help("Zoom the timeline")
        Text(String(format: "%.1f×", model.timelineZoom))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .leading)
        Button { model.fitTimeline() } label: {
            Image(systemName: "arrow.left.and.right.square")
        }
        .disabled(!model.isTimelineZoomed)
        .help("Fit entire timeline to window")
    }

    /// How many timeline lanes the bottom bar would currently show — a rough
    /// stand-in until the real timeline zone lands.
    private var visibleTimelineCount: Int {
        var count = 1 // main scrubber
        if model.showsLayoutTimeline { count += 1 }
        if model.showsCameraTimeline { count += 1 }
        if !model.textBlocks.isEmpty { count += 1 }
        if model.showsShapeTimeline { count += 1 }
        if model.showsZoomTimeline && model.hasCursorData { count += 1 }
        if model.showsSubtitleTimeline { count += 1 }
        return count
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00.0" }
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = total - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, secs)
    }
}
