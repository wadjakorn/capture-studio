import SwiftUI

/// Audio inspector — system/mic volume plus placeholders for the audio
/// features Screen Studio ships that Capture Studio doesn't yet (mic
/// enhancement, stereo mode, background music).
struct AudioInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.hasSystemAudioTrack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SYSTEM AUDIO").font(.caption).foregroundStyle(.secondary)
                    volumeSlider(systemImage: "speaker.wave.2", help: "System audio volume",
                                 value: Binding(get: { model.systemVolume },
                                                set: { model.setSystemVolume($0) }),
                                 fill: true, model: model)
                }
            }

            if model.hasMicTrack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MICROPHONE").font(.caption).foregroundStyle(.secondary)
                    volumeSlider(systemImage: "mic",
                                 help: "Microphone volume (up to 300% to boost quiet voice)",
                                 value: Binding(get: { model.micVolume },
                                                set: { model.setMicVolume($0) }),
                                 range: 0...3, showPercent: true, fill: true, model: model)

                    placeholderToggleRow("Improve microphone audio")
                    Text("Reduce noise and normalize volume")
                        .font(.caption2).foregroundStyle(.secondary)

                    placeholderToggleRow("Stereo mode")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("BACKGROUND AUDIO").font(.caption).foregroundStyle(.secondary)
                    soonBadge()
                }
                // 4 genre names overflow a segmented picker at the column
                // width (~272pt) — a menu keeps it inside the column.
                Picker("", selection: .constant(0)) {
                    Text("Lo-Fi").tag(0)
                    Text("Commercial").tag(1)
                    Text("Electronic").tag(2)
                    Text("Instrumental").tag(3)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(true)
                .opacity(0.5)

                VStack(alignment: .leading, spacing: 6) {
                    Button("Add background audio") {}
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(true)
                    HStack(spacing: 6) {
                        soonBadge()
                        Spacer(minLength: 0)
                    }
                }
                .opacity(0.55)
                .help("Coming soon — not yet available")
            }
        }
    }
}
