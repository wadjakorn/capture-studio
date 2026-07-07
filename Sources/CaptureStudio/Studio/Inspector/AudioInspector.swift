import SwiftUI

/// System audio / mic volume sliders shown in the bottom-bar tool group.
struct AudioInspector: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        if model.hasSystemAudioTrack {
            volumeSlider(systemImage: "speaker.wave.2", help: "System audio volume",
                         value: Binding(get: { model.systemVolume },
                                        set: { model.setSystemVolume($0) }),
                         model: model)
        }
        if model.hasMicTrack {
            volumeSlider(systemImage: "mic",
                         help: "Microphone volume (up to 300% to boost quiet voice)",
                         value: Binding(get: { model.micVolume },
                                        set: { model.setMicVolume($0) }),
                         range: 0...3, showPercent: true, model: model)
        }
    }
}
