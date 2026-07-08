import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Reframe (aspect ratio, pan, framing window) + background inspector — the
/// "Frame" rail tab. Mirrors the bottom bar's `reframeControls` +
/// `backgroundControls` content, arranged as titled sections.
struct FrameInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Aspect ratio") {
                Menu {
                    ForEach(CropAspect.allCases, id: \.self) { aspect in
                        Button {
                            model.setCropAspect(aspect)
                        } label: {
                            if model.cropAspect == aspect {
                                Label(aspect.displayName, systemImage: "checkmark")
                            } else {
                                Text(aspect.displayName)
                            }
                        }
                    }
                } label: {
                    Label(model.cropAspect.displayName, systemImage: "aspectratio")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.button)
                .help("Reframe aspect ratio")
            }

            section("Reposition") {
                inspectorToggleRow("Pan video", systemImage: "hand.draw",
                                    isOn: Binding(get: { model.panVideoMode },
                                                  set: { model.panVideoMode = $0 }))
                .disabled(!model.cropPannable)
                .help("Move/pan the reframed video — drag the canvas to reposition it")

                if model.cropPannable {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { 1.2 - model.cropZoom },
                                              set: { model.setCropZoom(1.2 - $0) }),
                               in: 0.2...1.0) { editing in
                            if !editing { model.commitCropEdit() }
                        }
                        .controlSize(.small)
                    }
                    .help("Crop zoom — drag the video to pan")
                }

                inspectorToggleRow("Safe-area guide", systemImage: "rectangle.dashed",
                                    isOn: Binding(get: { model.templateGuideVisible },
                                                  set: { model.templateGuideVisible = $0 }))
                .disabled(model.cropAspect != .nineBySixteenTemplate)
                .help("Toggle reels safe-area guide")
            }

            section("Framing window") {
                inspectorToggleRow("Enable framing window", systemImage: "inset.filled.rectangle",
                                    isOn: Binding(get: { model.frameEnabled },
                                                  set: { model.setFrameEnabled($0) }))
                .help("Framing window — mask the main video to a static rectangle it pans behind")

                if model.frameEnabled {
                    inspectorToggleRow("Show handles", systemImage: "slider.horizontal.below.rectangle",
                                        isOn: Binding(get: { model.frameEditMode },
                                                      set: { model.frameEditMode = $0 }))
                    .help("Show framing window transform handles")

                    Button { model.resetFrame() } label: {
                        Label("Reset to full center", systemImage: "arrow.uturn.backward")
                    }
                    .help("Reset framing window to full center")
                }
            }

            if model.cropAspect.isFit {
                section("Background") { backgroundControls }
            }

            section("Backdrop") {
                placeholderToggleRow("Wallpaper / gradient")
            }
        }
        .padding(16)
    }

    /// Letterbox-bar background controls, shown only in template/fit mode:
    /// pick Black / Blur / Photo, a blur-amount slider, and a delete button.
    @ViewBuilder private var backgroundControls: some View {
        Menu {
            Button { model.setCanvasBackground(.black) } label: {
                if model.canvasBackground == .black {
                    Label("Black", systemImage: "checkmark")
                } else { Text("Black") }
            }
            Button { model.setCanvasBackground(.blur) } label: {
                if model.canvasBackground == .blur {
                    Label("Blur", systemImage: "checkmark")
                } else { Text("Blur") }
            }
            Button { pickBackgroundImage() } label: {
                if model.canvasBackground == .image {
                    Label("Photo…", systemImage: "checkmark")
                } else { Text("Photo…") }
            }
        } label: {
            Label("Fill", systemImage: "photo.artframe")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.button)
        .help("Background fill for the letterbox bars")

        if model.canvasBackground == .blur {
            HStack(spacing: 4) {
                Image(systemName: "drop").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.canvasBackgroundBlur },
                                      set: { model.setCanvasBackgroundBlur($0) }),
                       in: 0...0.2) { editing in
                    if !editing { model.commitCanvasBackgroundBlur() }
                }
                .controlSize(.small)
            }
            .help("Background blur amount")
        }

        if model.canvasBackground == .image {
            Button(role: .destructive) { model.deleteBackgroundImage() } label: {
                Label("Remove photo", systemImage: "trash")
            }
        }
    }

    /// Pick an image file and set it as the canvas background.
    private func pickBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.uploadBackgroundImage(from: url)
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
