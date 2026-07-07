import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Namespace for the two caption-related style panels: per-block text style
/// and the shared subtitle-track style.
enum CaptionsInspector {

    /// Container for the Captions rail tab — a Text | Subtitles switcher so
    /// the two style panels don't stack (each has its own font picker, etc).
    /// Follows selection: picking a text block on canvas/timeline switches to
    /// Text; enabling subtitle positioning switches to Subtitles.
    struct CaptionsPanel: View {
        @ObservedObject var model: StudioModel
        @State private var section: Section = .text

        enum Section: Hashable { case text, subtitles }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $section) {
                    Text("Text").tag(Section.text)
                    Text("Subtitles").tag(Section.subtitles)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch section {
                case .text: TextSection(model: model)
                case .subtitles: SubtitleSection(model: model)
                }
            }
            .onChange(of: model.subtitleSelected) { _, selected in
                if selected { section = .subtitles }
            }
            .onChange(of: model.selectedTextBlockID != nil) { _, selected in
                if selected { section = .text }
            }
        }
    }

    /// Per-block caption text style — font, weight, align, size, color, box,
    /// outline, shadow.
    struct TextSection: View {
        @ObservedObject var model: StudioModel

        var body: some View {
            let block = model.selectedTextBlock
            VStack(alignment: .leading, spacing: 12) {
                    // Add / z-order / delete for the selected block — always
                    // shown, disabled until a block is selected (add is not).
                    HStack(spacing: 8) {
                        Button { model.addTextBlock() } label: {
                            Image(systemName: "text.badge.plus")
                        }
                        .help("Add a text/caption block at the playhead")

                        Button {
                            if let id = model.selectedTextBlockID { model.sendTextBackward(id) }
                        } label: { Image(systemName: "arrow.down.square") }
                            .disabled(block == nil)
                            .help("Send backward")
                        Button {
                            if let id = model.selectedTextBlockID { model.bringTextForward(id) }
                        } label: { Image(systemName: "arrow.up.square") }
                            .disabled(block == nil)
                            .help("Bring forward")
                        Button(role: .destructive) {
                            if let id = model.selectedTextBlockID { model.removeTextBlock(id) }
                        } label: { Image(systemName: "trash") }
                            .disabled(block == nil)
                            .help("Delete this text block")
                    }

                    // Inline caption input — always shown; editable only
                    // while a text block is selected (timeline or canvas),
                    // greyed out otherwise.
                    CaptionTextEditor(
                        text: Binding(
                            get: { model.selectedTextBlock?.text ?? "" },
                            set: { if let id = model.selectedTextBlockID { model.setText($0, for: id) } }
                        ),
                        isEnabled: model.selectedTextBlock != nil,
                        focusToken: model.selectedTextBlockID,
                        onSubmit: { model.commitTextEdit() },
                        onCancel: { model.deselectAll() }
                    )
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.secondary.opacity(0.3), lineWidth: 1))
                    .opacity(block == nil ? 0.55 : 1)
                    .help(block == nil
                          ? "Select a text block to edit its caption"
                          : "Edit caption text · Shift+Return for a new line")

                    Divider()

                    Picker("Font", selection: Binding(
                        get: { block?.fontName ?? "Helvetica" },
                        set: { model.setTextFontName($0) }
                    )) {
                        ForEach(inspectorFontFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()

                    Picker("Weight", selection: Binding(
                        get: { block?.fontWeight ?? .semibold },
                        set: { model.setTextWeight($0) }
                    )) {
                        ForEach(TextWeight.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    Picker("Align", selection: Binding(
                        get: { block?.alignment ?? .center },
                        set: { model.setTextAlignment($0) }
                    )) {
                        Image(systemName: "text.alignleft").tag(TextAlignmentH.leading)
                        Image(systemName: "text.aligncenter").tag(TextAlignmentH.center)
                        Image(systemName: "text.alignright").tag(TextAlignmentH.trailing)
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    textSizeRow(block)

                    Toggle("Auto-wrap lines", isOn: Binding(
                        get: { block?.autoWrap ?? true },
                        set: { model.setTextAutoWrap($0) }
                    ))
                    if block?.autoWrap ?? true {
                        styleSliderText("Box width", value: Binding(
                            get: { block?.boxWidth ?? 0.9 },
                            set: { model.setTextBoxWidth($0) }
                        ), range: 0.05...1.0, model: model)
                    }

                    textColorRow("Color", hex: block?.colorHex ?? "#FFFFFF") {
                        model.setTextColorHex($0)
                    }

                    Toggle("Background box", isOn: Binding(
                        get: { block?.boxEnabled ?? false },
                        set: { model.setTextBoxEnabled($0) }
                    ))
                    if block?.boxEnabled == true {
                        textColorRow("Box color", hex: block?.boxHex ?? "#000000") {
                            model.setTextBoxHex($0)
                        }
                        styleSliderText("Box opacity", value: Binding(
                            get: { block?.boxOpacity ?? 0.5 },
                            set: { model.setTextBoxOpacity($0) }
                        ), range: 0...1, model: model)
                    }

                    styleSliderText("Outline", value: Binding(
                        get: { block?.strokeWidth ?? 0 },
                        set: { model.setTextStrokeWidth($0) }
                    ), range: 0...0.2, model: model)
                    if (block?.strokeWidth ?? 0) > 0 {
                        textColorRow("Outline color", hex: block?.strokeHex ?? "#000000") {
                            model.setTextStrokeHex($0)
                        }
                    }

                    Toggle("Shadow", isOn: Binding(
                        get: { block?.shadow ?? true },
                        set: { model.setTextShadow($0) }
                    ))
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// Font-size control showing the rendered px height, with a ±1px stepper
        /// and a slider. `fontSize` is a fraction of canvas height, so px =
        /// fontSize × renderSize.height (falls back to 1080 before the canvas
        /// size is known).
        @ViewBuilder
        private func textSizeRow(_ block: TextBlock?) -> some View {
            let h = model.renderSize.height > 0 ? model.renderSize.height : 1080
            let frac = block?.fontSize ?? 0.06
            let px = Int((frac * h).rounded())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Size").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(px) px").font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("", value: Binding(
                        get: { Double(px) },
                        set: { model.setTextFontSize($0 / h); model.commitTextEdit() }
                    ), in: 1...(h * 0.5), step: 1)
                    .labelsHidden()
                }
                Slider(value: Binding(
                    get: { block?.fontSize ?? 0.06 },
                    set: { model.setTextFontSize($0) }
                ), in: 0.005...0.2) { editing in
                    if !editing { model.commitTextEdit() }
                }
            }
        }
    }

    /// Shared subtitle-track style — applies to every cue: offset, font,
    /// weight, align, size, color, box, outline, shadow.
    struct SubtitleSection: View {
        @ObservedObject var model: StudioModel
        @State private var confirmRemoveSubtitles = false

        var body: some View {
            let style = model.subtitles?.style
            VStack(alignment: .leading, spacing: 12) {
                    // Import / remove — the style controls below only apply
                    // once a subtitle track exists.
                    if model.subtitles == nil {
                        Button { pickSubtitleFile() } label: {
                            Label("Import subtitles…", systemImage: "captions.bubble")
                        }
                        .disabled(model.subtitleState != .idle)
                        .help("Import subtitles from an .srt file")
                    } else {
                        HStack(spacing: 8) {
                            Button(role: .destructive) { confirmRemoveSubtitles = true } label: {
                                Label("Remove subtitles", systemImage: "trash")
                            }
                            .disabled(model.subtitleState != .idle)
                            .help("Remove subtitles")
                            .confirmationDialog("Remove subtitles?", isPresented: $confirmRemoveSubtitles,
                                                titleVisibility: .visible) {
                                Button("Remove Subtitles", role: .destructive) { model.removeSubtitles() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This removes the imported subtitle track from this project.")
                            }

                            if model.subtitleState != .idle {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }

                    // Position on canvas — enabling drives SubtitleCanvasOverlay
                    // so the cue can be dragged to reposition it. Not auto-enabled
                    // (subtitleSelected feeds the inspector router), so it's an
                    // explicit toggle here; Esc / deselect clears it.
                    if model.subtitles != nil {
                        Toggle("Position on canvas", isOn: Binding(
                            get: { model.subtitleSelected },
                            set: { model.selectSubtitles($0) }
                        ))
                        .disabled(model.subtitleState != .idle)
                        .help("Drag the subtitle on the canvas to reposition it")
                    }

                    Text("Applies to all subtitles").font(.caption).foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Time offset (s)").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("", value: Binding(
                                get: { model.subtitles?.offset ?? 0 },
                                set: { model.setSubtitleOffset($0) }
                            ), format: .number.precision(.fractionLength(2)))
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                            Stepper("", value: Binding(
                                get: { model.subtitles?.offset ?? 0 },
                                set: { model.setSubtitleOffset($0) }
                            ), in: -86_400...86_400, step: 0.1)
                                .labelsHidden()
                            Spacer()
                            Button("Set from playhead") { model.setSubtitleOffsetFromPlayhead() }
                                .controlSize(.small)
                        }
                        Text("SRT made from the raw (untrimmed) video? Nudge or set from the playhead to re-sync.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .disabled(model.subtitleState != .idle)

                    Divider()

                    Picker("Font", selection: Binding(
                        get: { style?.fontName ?? "Helvetica" },
                        set: { model.setSubtitleFontName($0) }
                    )) {
                        ForEach(inspectorFontFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()

                    Picker("Weight", selection: Binding(
                        get: { style?.fontWeight ?? .semibold },
                        set: { model.setSubtitleWeight($0) }
                    )) {
                        ForEach(TextWeight.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    Picker("Align", selection: Binding(
                        get: { style?.alignment ?? .center },
                        set: { model.setSubtitleAlignment($0) }
                    )) {
                        Image(systemName: "text.alignleft").tag(TextAlignmentH.leading)
                        Image(systemName: "text.aligncenter").tag(TextAlignmentH.center)
                        Image(systemName: "text.alignright").tag(TextAlignmentH.trailing)
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    styleSliderSubtitle("Size", value: Binding(
                        get: { style?.fontSize ?? 0.05 },
                        set: { model.setSubtitleFontSize($0) }
                    ), range: 0.02...0.2, model: model)

                    styleSliderSubtitle("Box width (wrap)", value: Binding(
                        get: { style?.boxWidth ?? 0.9 },
                        set: { model.setSubtitleBoxWidth($0) }
                    ), range: 0.05...1.0, model: model)

                    textColorRow("Color", hex: style?.colorHex ?? "#FFFFFF") {
                        model.setSubtitleColorHex($0)
                    }

                    Toggle("Background box", isOn: Binding(
                        get: { style?.boxEnabled ?? false },
                        set: { model.setSubtitleBoxEnabled($0) }
                    ))
                    if style?.boxEnabled == true {
                        textColorRow("Box color", hex: style?.boxHex ?? "#000000") {
                            model.setSubtitleBoxHex($0)
                        }
                        styleSliderSubtitle("Box opacity", value: Binding(
                            get: { style?.boxOpacity ?? 0.5 },
                            set: { model.setSubtitleBoxOpacity($0) }
                        ), range: 0...1, model: model)
                    }

                    styleSliderSubtitle("Outline", value: Binding(
                        get: { style?.strokeWidth ?? 0 },
                        set: { model.setSubtitleStrokeWidth($0) }
                    ), range: 0...0.2, model: model)
                    if (style?.strokeWidth ?? 0) > 0 {
                        textColorRow("Outline color", hex: style?.strokeHex ?? "#000000") {
                            model.setSubtitleStrokeHex($0)
                        }
                    }

                    Toggle("Shadow", isOn: Binding(
                        get: { style?.shadow ?? true },
                        set: { model.setSubtitleShadow($0) }
                    ))

                    Divider()

                    Text("Scrub to a subtitle, then drag it on the canvas to reposition.")
                        .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// Pick a `.srt` file and apply it as the subtitle track.
        private func pickSubtitleFile() {
            let panel = NSOpenPanel()
            if let srt = UTType(filenameExtension: "srt") {
                panel.allowedContentTypes = [srt, .text]
            } else {
                panel.allowedContentTypes = [.text]
            }
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            if panel.runModal() == .OK, let url = panel.url {
                model.importSubtitles(from: url)
            }
        }
    }
}
