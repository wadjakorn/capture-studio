import SwiftUI

/// Bottom transport chrome: play/pause + timecode, trim controls, plus a
/// speed placeholder and a "timelines visible" label. Mirrors the bottom
/// bar's `transportControls` + `trimControls`. Not yet wired into
/// `StudioView` — Task 5 swaps the layout to use this.
struct StudioTransportBar: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        HStack(spacing: 12) {
            transportControls
            Divider().frame(height: 16)
            trimControls
            Divider().frame(height: 16)
            splitControls
            Divider().frame(height: 16)
            Text("1×").font(.caption.monospacedDigit()).comingSoon()
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

    @ViewBuilder private var trimControls: some View {
        Button("Set In") { model.setTrimIn(model.currentTime) }
        Button("Set Out") { model.setTrimOut(model.currentTime) }
        Button { model.resetTrim() } label: { Image(systemName: "arrow.uturn.backward") }
            .help("Reset trim")
        Button { model.applyTrim() } label: { Image(systemName: "scissors") }
            .disabled(!model.canApplyTrim)
            .help("Apply trim — cut everything outside In/Out off the timeline")
        Text("\(timecode(model.trimIn)) – \(timecode(model.trimOut))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Split the master timeline at the playhead, then cut (hide) / restore the
    /// segment under the playhead — non-destructive, cleared by Reset.
    @ViewBuilder private var splitControls: some View {
        Button { model.splitAtPlayhead() } label: {
            Image(systemName: "square.split.2x1")
        }
        .disabled(!model.canSplitAtPlayhead)
        .help("Split the timeline at the playhead")

        Button { model.toggleCutAtPlayhead() } label: {
            Image(systemName: cutIsRestore ? "eye" : "eye.slash")
        }
        .disabled(!model.canToggleCutAtPlayhead)
        .help(cutIsRestore ? "Restore this segment" : "Cut this segment from the video")

        Button { model.resetSegments() } label: { Image(systemName: "arrow.uturn.backward") }
            .disabled(!model.canResetSegments)
            .help("Clear all splits and cuts")

        if model.hasCutSegments {
            Text("\(model.segments.filter(\.hidden).count) cut")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// True when the playhead sits on an already-hidden segment (so the toggle
    /// restores rather than cuts).
    private var cutIsRestore: Bool { model.segmentAtPlayhead?.hidden == true }

    /// How many timeline lanes the bottom bar would currently show — a rough
    /// stand-in until the real timeline zone lands.
    private var visibleTimelineCount: Int {
        var count = 1 // main scrubber
        if model.showsLayoutTimeline { count += 1 }
        if model.showsCameraTimeline { count += 1 }
        if !model.textBlocks.isEmpty { count += 1 }
        if model.showsShapeTimeline { count += 1 }
        if model.showsZoomTimeline { count += 1 }
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
