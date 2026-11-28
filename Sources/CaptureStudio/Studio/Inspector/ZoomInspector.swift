import SwiftUI

/// Zoom blocks, top to bottom in the order of the work: make blocks, then for
/// the selected one — what it shows, how close, how it moves, what happens at
/// the picture's edge — and finally "use this everywhere".
///
/// Rules of the panel: a control that does not apply is not shown; one that
/// applies but cannot work yet is shown disabled with the reason, and the way
/// out, right next to it.
struct ZoomInspector: View {
    @ObservedObject var model: StudioModel
    /// Blocks exist: confirm before auto zoom replaces them all.
    @State private var confirmReplaceAll = false
    /// The last auto zoom found no clicks or typing in range.
    @State private var autoZoomFoundNothing = false
    /// The zoom blocks changed while the video was analysed; nothing was replaced.
    @State private var autoZoomSkipped = false

    private typealias Choice = StudioModel.ZoomShowChoice

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
            create
            Divider()
            if let block = model.selectedZoomBlock {
                blockHeader(block)
                showSection
                storySection
                zoomSection(block)
                motionSection
                edgeSection
                Divider()
                Button { model.applySelectedZoomFollowSettingsToAll() } label: {
                    Label(model.selectedZoomShowChoice == .spot
                          ? "Use motion & edge settings for all blocks"
                          : "Use these settings for all blocks",
                          systemImage: "square.on.square")
                }
                .help(model.selectedZoomShowChoice == .spot
                      ? "Give every zoom block this one's motion and edge settings — also blocks added later and by Auto zoom."
                      : "Give every zoom block what this one shows, its zoom range, motion and edge settings — also blocks added later and by Auto zoom. Each block keeps its own zoom level.")
            } else {
                Text(emptyPrompt)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.selectedZoomBlockID) { _, _ in
            autoZoomFoundNothing = false
            autoZoomSkipped = false
        }
    }

    private var emptyPrompt: String {
        if !model.hasCursorData { return "Zoom needs pointer data from a screen recording." }
        if model.zoomBlocks.isEmpty {
            return "Press Auto zoom to make zoom blocks from your clicks and typing, or add one at the playhead."
        }
        return "Select a zoom block on the timeline to adjust it."
    }

    // MARK: - Create

    private var create: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if model.zoomBlocks.isEmpty { runAutoZoom(.all) } else { confirmReplaceAll = true }
                } label: {
                    Label("Auto zoom", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canAutoZoom || model.autoZoomAnalysisProgress != nil)
                .help(model.canAutoZoom
                      ? "Make zoom blocks from the clicks and typing in this recording"
                      : "Zoom needs pointer data from a screen recording")
                .confirmationDialog("Replace \(model.zoomBlocks.count) zoom blocks?",
                                    isPresented: $confirmReplaceAll, titleVisibility: .visible) {
                    Button("Replace all") { runAutoZoom(.all) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Auto zoom makes new blocks for the whole recording. To redo one block only, select it and use its Redo button.")
                }

                Button { model.addZoomBlock() } label: {
                    Label("Add block", systemImage: "plus")
                }
                .disabled(!model.hasCursorData)
                .help(model.hasCursorData
                      ? "Add a zoom block at the playhead"
                      : "Zoom needs pointer data from a screen recording")
            }
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
                .help("Looking at what changes on screen, once per project.")
            }
            if autoZoomSkipped {
                note("The zoom blocks changed while the video was analysed, so nothing was replaced. Press Auto zoom again.")
            }
            if autoZoomFoundNothing {
                note("Nothing to zoom on here — no clicks or typing in range, or the range is too short.")
            }
        }
    }

    // MARK: - Block

    /// Where the block came from: what Auto zoom saw there, or the user.
    /// nil when the project does not say (blocks from before this was kept).
    static func origin(_ made: ZoomMade?) -> String? {
        guard let made else { return nil }
        if made.byHand { return "Added by hand" }
        var parts: [String] = []
        if made.clicks > 0 { parts.append(made.clicks == 1 ? "1 click" : "\(made.clicks) clicks") }
        if made.drags > 0 { parts.append(made.drags == 1 ? "1 drag" : "\(made.drags) drags") }
        if made.typing { parts.append("typing") }
        guard !parts.isEmpty else { return "Made by Auto zoom" }
        let list = parts.count > 1
            ? parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
            : parts[0]
        return "Made by Auto zoom from \(list)"
    }

    /// One line per stretch of the block: what the picture stays with, and how close.
    static func phaseLine(_ p: ZoomPhase) -> String {
        let what: String
        switch p.kind {
        case .window: what = "On the window"
        case .both: what = "Window and pointer"
        case .pointer: what = "With the pointer"
        case .holdWindow: what = "On the window (pointer elsewhere)"
        case .spot: what = "Fixed spot"
        }
        return String(format: "%@ – %@   %@ · %.1f×", clock(p.begin), clock(p.end), what, p.scale)
    }

    /// The clicks whose opened content the picture leans toward, by time —
    /// each second once, the first few only.
    static func leanLine(_ times: [Double]) -> String? {
        var clocks: [String] = []
        for t in times.sorted() where clocks.last != clock(t) { clocks.append(clock(t)) }
        guard !clocks.isEmpty else { return nil }
        let shown = clocks.prefix(4).joined(separator: ", ")
        let more = clocks.count > 4 ? " and \(clocks.count - 4) more" : ""
        return "Leans toward what a click opened at \(shown)\(more)."
    }

    /// What this block actually does — so "what is it following?" has an answer
    /// without playing it.
    @ViewBuilder
    private var storySection: some View {
        if let story = model.selectedZoomStory, !story.phases.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                heading("In this block", "list.bullet")
                ForEach(Array(story.phases.enumerated()), id: \.offset) { _, phase in
                    Text(Self.phaseLine(phase))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let leans = Self.leanLine(story.leans) { note(leans) }
            }
        }
    }

    private func blockHeader(_ block: ZoomBlock) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            blockTitle(block)
            if let origin = Self.origin(block.made) { note(origin) }
        }
    }

    private func blockTitle(_ block: ZoomBlock) -> some View {
        HStack(spacing: 6) {
            Text("Block \(Self.clock(block.begin)) – \(Self.clock(block.end))")
                .font(.headline.monospacedDigit())
            Spacer(minLength: 4)
            Button("Redo") { runAutoZoom(.block(block.id)) }
                .disabled(!model.canAutoZoom || model.autoZoomAnalysisProgress != nil)
                .help("Run Auto zoom on this stretch only, keeping this block's settings")
            Button { model.splitZoomBlockAtPlayhead() } label: {
                Image(systemName: "square.split.2x1")
            }
            .disabled(!model.canSplitSelectedZoomAtPlayhead)
            .help("Split this block at the playhead, so each part can have its own settings")
            Button(role: .destructive) { model.removeZoomBlock(block.id) } label: {
                Image(systemName: "trash")
            }
            .help("Delete this zoom block")
        }
        .buttonStyle(.borderless)
    }

    // MARK: - 1 Show

    private var showSection: some View {
        let choice = model.selectedZoomShowChoice
        return VStack(alignment: .leading, spacing: 4) {
            heading("Show", "eye")
            Menu {
                showItem(.auto, "Decide for me")
                showItem(.pointer, "The pointer")
                showItem(.window, "The window")
                showItem(.both, "Window and pointer")
                Divider()
                showItem(.spot, "A fixed spot")
            } label: {
                // The same symbol the block carries on the timeline.
                Label(Self.title(choice), systemImage: Self.symbol(choice))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            note(showHelp(choice))
        }
    }

    /// The window framings need window data; the rest always work.
    private func needsWindowData(_ choice: Choice) -> Bool {
        (choice == .window || choice == .both) && !model.hasWindowData
    }

    private func showItem(_ choice: Choice, _ title: String) -> some View {
        let missing = needsWindowData(choice)
        return Button {
            model.setZoomShowChoice(choice)
        } label: {
            let text = missing ? "\(title) — needs a recording made with this version" : title
            if model.selectedZoomShowChoice == choice {
                Label(text, systemImage: "checkmark")
            } else {
                Text(text)
            }
        }
        .disabled(missing)
    }

    private static func symbol(_ choice: Choice) -> String {
        switch choice {
        case .auto: return "sparkles"
        case .pointer: return "cursorarrow"
        case .window: return "macwindow"
        case .both: return "macwindow.and.cursorarrow"
        case .spot: return "pin.fill"
        }
    }

    private static func title(_ choice: Choice) -> String {
        switch choice {
        case .auto: return "Decide for me"
        case .pointer: return "The pointer"
        case .window: return "The window"
        case .both: return "Window and pointer"
        case .spot: return "A fixed spot"
        }
    }

    private func showHelp(_ choice: Choice) -> String {
        if needsWindowData(choice) || (choice == .auto && !model.hasWindowData) {
            return "This recording has no window data (it was made with an earlier version), so there is no window to stay with: the picture goes with the pointer."
        }
        switch choice {
        case .auto:
            return "Stays with the window you are working in. A short trip outside it zooms out to show both; a longer one follows the pointer."
        case .pointer:
            return "Follows the pointer wherever it goes."
        case .window:
            return "Stays on the window you spend the most time in during this block. The pointer may leave the picture."
        case .both:
            return "Keeps the window and the pointer in the picture, zooming out when the pointer leaves the window."
        case .spot:
            return "Holds one framing. Drag the target on the canvas to place it. Split a block to hold only part of it."
        }
    }

    // MARK: - 2 Zoom

    @ViewBuilder
    private func zoomSection(_ block: ZoomBlock) -> some View {
        let spot = model.selectedZoomShowChoice == .spot
        // A range needs something to fit: window data or an analysed video.
        let nothingToFit = !model.hasWindowData && !model.hasContentAnalysis
        let ranged = !spot && block.auto != nil
        VStack(alignment: .leading, spacing: 6) {
            heading("Zoom", "arrow.up.left.and.arrow.down.right")
            if !spot {
                Picker("Zoom", selection: Binding(get: { ranged },
                                                  set: { model.setZoomRangeEnabled($0) })) {
                    Text("One level").tag(false)
                    Text("A range").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(nothingToFit && !ranged)
            }
            if ranged, let auto = block.auto {
                HStack {
                    Text("Changes by itself between")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f× – %.1f×", auto.min, auto.max))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                RangeSlider(
                    lower: Binding(get: { auto.min }, set: { v in
                        var a = auto
                        a.min = v
                        model.setZoomAuto(a)
                    }),
                    upper: Binding(get: { auto.max }, set: { v in
                        var a = auto
                        a.max = v
                        model.setZoomAuto(a)
                    }),
                    bounds: ZoomAutoScale.scaleLimits,
                    lowerLabel: "Least zoom", upperLabel: "Most zoom",
                    onEditingChanged: { editing in if !editing { model.commitZoomEdit() } })
                inspectorToggleRow("Make room for menus and pop-ups",
                                   isOn: Binding(get: { auto.fitReveals && model.hasContentAnalysis },
                                                 set: { on in
                                                     var a = auto
                                                     a.fitReveals = on
                                                     model.setZoomAuto(a)
                                                     model.commitZoomEdit()
                                                 }))
                    .disabled(!model.hasContentAnalysis)
                if !model.hasContentAnalysis {
                    analyseRow("Needs the video analysed for what clicks open.")
                }
                if nothingToFit {
                    note("Nothing to fit the zoom to yet in this recording, so it stays at one level.")
                }
            } else {
                HStack {
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
                if !spot && nothingToFit {
                    analyseRow("A range needs something to fit the zoom to: window data, or the video analysed.")
                }
            }
            if spot {
                Button { model.centerManualTargetOnCursor() } label: {
                    Label("Centre on the pointer here", systemImage: "cursorarrow")
                }
                .disabled(!model.hasCursorData)
            }
        }
    }

    /// A reason plus the way out: analyse the video (or why that is not possible).
    private func analyseRow(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            note(reason)
            if model.autoZoomAnalysisProgress != nil {
                note("Analysing…")
            } else if model.analysisFailed || !model.canAutoZoom {
                note("The video could not be read, so this is not available.")
            } else {
                Button("Analyse video") { Task { await model.analyseVideoForZoom() } }
                    .controlSize(.small)
                    .help("Looks at what changes on screen, once per project. Nothing is replaced; blocks that follow may re-frame toward what clicks open.")
            }
        }
    }

    // MARK: - 3 Motion

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("Motion", "hand.draw")
            Slider(
                value: Binding(get: { model.selectedZoomSensitivity },
                               set: { model.setZoomSensitivity($0) }),
                in: 0...1,
                label: { Text("Motion") },
                minimumValueLabel: { Text("Calm").font(.caption2).foregroundStyle(.secondary) },
                maximumValueLabel: { Text("Snappy").font(.caption2).foregroundStyle(.secondary) },
                onEditingChanged: { editing in if !editing { model.commitZoomEdit() } }
            )
            .labelsHidden()
            note(model.selectedZoomShowChoice == .spot
                 ? "How quickly the picture zooms and moves to this spot."
                 : "Calm holds the picture longer and glides; snappy stays close to the pointer.")
        }
    }

    // MARK: - 4 Edge

    private var edgeSection: some View {
        // Holding a window means stopping at the edge; the block's own choice
        // is kept for when it shows something else.
        let held = model.selectedZoomHoldsWindow
        let centred = !held && model.selectedZoomOverflow
        return VStack(alignment: .leading, spacing: 4) {
            heading("At the picture's edge", "rectangle.dashed")
            Picker("At the picture's edge",
                   selection: Binding(get: { centred }, set: { model.setZoomOverflow($0) })) {
                Text("Stop at the edge").tag(false)
                Text("Keep centred").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(held)
            if held {
                note("The window is kept in the picture, so the picture stops at its edge.")
            } else if centred {
                note(model.selectedZoomShowChoice == .auto
                     ? "The pointer stays in the middle and the background shows past the edge. The picture is then not held to a window."
                     : "The pointer stays in the middle and the background shows past the edge.")
            } else {
                note("The picture never shows past its own edge.")
            }
        }
    }

    // MARK: - Pieces

    private func heading(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// m:ss.
    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
