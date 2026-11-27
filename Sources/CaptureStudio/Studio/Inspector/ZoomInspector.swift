import SwiftUI

/// Per-block zoom controls (scale + follow sensitivity + overflow) — operates
/// on the selected move/zoom block.
struct ZoomInspector: View {
    @ObservedObject var model: StudioModel
    /// Blocks exist: ask whether auto zoom replaces all of them or just one.
    @State private var askAutoZoomScope = false
    /// The last auto zoom found no clicks or typing in range.
    @State private var autoZoomFoundNothing = false
    /// The zoom blocks changed while the video was analysed; nothing was replaced.
    @State private var autoZoomSkipped = false

    /// Run auto zoom, or ask for the scope first when there are blocks to replace.
    private func autoZoomTapped() {
        if model.zoomBlocks.isEmpty {
            runAutoZoom(.all)
        } else {
            askAutoZoomScope = true
        }
    }

    private func runAutoZoom(_ scope: AutoZoomScope) {
        autoZoomFoundNothing = false
        autoZoomSkipped = false
        Task {
            let outcome = await model.runAutoZoom(scope: scope)
            autoZoomFoundNothing = outcome == .nothingFound
            autoZoomSkipped = outcome == .editedMeanwhile
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Add / delete — add is also available via the timeline zoom
            // lane; this button is a convenient duplicate.
            HStack(spacing: 8) {
                Button { model.addZoomBlock() } label: {
                    Label("Add zoom", systemImage: "plus.magnifyingglass")
                }
                .disabled(!model.hasCursorData)
                .help(model.hasCursorData
                      ? "Add an auto zoom/pan block at the playhead"
                      : "Zoom needs cursor data from a screen recording")

                Button(role: .destructive) {
                    if let id = model.selectedZoomBlockID { model.removeZoomBlock(id) }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.selectedZoomBlockID == nil)
                .help("Delete the selected zoom block")
            }

            // Generate blocks from the recorded clicks / typing.
            if let progress = model.autoZoomAnalysisProgress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                        Button("Cancel") { model.cancelAutoZoomAnalysis() }
                            .controlSize(.small)
                    }
                    Text("Analysing video… \(Int((progress * 100).rounded()))%")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .help("Looking at what changes on screen, once per project. Cancel to zoom from clicks and typing alone.")
            }
            Button { autoZoomTapped() } label: {
                Label("Auto zoom", systemImage: "wand.and.stars")
            }
            .disabled(!model.canAutoZoom || model.autoZoomAnalysisProgress != nil)
            .help(model.canAutoZoom
                  ? "Create zoom blocks from clicks and typing in this recording"
                  : "Zoom needs cursor data from a screen recording")
            .confirmationDialog("Auto zoom", isPresented: $askAutoZoomScope,
                                titleVisibility: .visible) {
                Button("All blocks (replace \(model.zoomBlocks.count))") { runAutoZoom(.all) }
                if let id = model.selectedZoomBlockID {
                    Button("Only this block") { runAutoZoom(.block(id)) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Replace zoom blocks with ones generated from clicks and typing.")
            }
            if autoZoomSkipped {
                Text("The zoom blocks changed while the video was analysed, so nothing was replaced. Press Auto zoom again.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if autoZoomFoundNothing {
                Text("Nothing to zoom on here — no clicks or typing in range, or the range is too short.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Split the block at the playhead into two touching segments (a
            // start/stop point) so follow and manual can alternate without the
            // zoom dropping back out.
            Button { model.splitZoomBlockAtPlayhead() } label: {
                Label("Split at playhead", systemImage: "square.split.2x1")
            }
            .disabled(!model.canSplitSelectedZoomAtPlayhead)
            .help("Split the selected zoom block at the playhead so you can switch follow/manual mid-zoom")

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Label("Mode", systemImage: "cursorarrow.motionlines")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Mode", selection: Binding(get: { model.selectedZoomMode },
                                                  set: { model.setZoomMode($0) })) {
                    Text("Follow mouse").tag(ZoomMode.follow)
                    Text("Manual").tag(ZoomMode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.selectedZoomBlockID == nil)
                Text(model.selectedZoomMode == .manual
                     ? "Holds a fixed frame; ignores the cursor for this segment."
                     : "Pans to follow the cursor.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f×", model.selectedZoomScale))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { model.selectedZoomScale },
                                   set: { model.setZoomScale($0) }),
                    in: 1...6,
                    onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
                )
            }

            if model.selectedZoomMode == .manual {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Manual target", systemImage: "scope")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { model.centerManualTargetOnCursor() } label: {
                        Label("Center on cursor at playhead", systemImage: "cursorarrow")
                    }
                    .disabled(!model.hasCursorData)
                    Text("Seeded when you switch from follow at a split. Drag the reticle on the canvas to reposition, or re-center on the cursor here.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Follow sensitivity", systemImage: "hand.draw")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((model.selectedZoomSensitivity * 100).rounded()))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(get: { model.selectedZoomSensitivity },
                                       set: { model.setZoomSensitivity($0) }),
                        in: 0...1,
                        onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
                    )
                    Text("How readily the frame moves to follow the cursor — low = holds longer and glides, high = follows closely.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                inspectorToggleRow("Overflow inside frame", systemImage: "rectangle.expand.vertical",
                                    isOn: Binding(get: { model.selectedZoomOverflow },
                                                  set: { model.setZoomOverflow($0) }))
                Text("Let the pan run past the video edge so the background shows inside the frame at the edges (cursor stays centred in the frame). Off keeps the video filling the frame. The video is always clipped to the frame either way.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Make this block's follow sensitivity + overflow the project setting.
            Button { model.applySelectedZoomFollowSettingsToAll() } label: {
                Label("Apply sensitivity & overflow to all blocks",
                      systemImage: "square.on.square")
            }
            .disabled(model.selectedZoomBlockID == nil)
            .help("Use this block's follow sensitivity and overflow for every zoom block in this project, including blocks added later and by Auto zoom")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.selectedZoomBlockID) { _, _ in autoZoomFoundNothing = false }
    }
}
