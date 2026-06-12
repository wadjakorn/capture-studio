import SwiftUI
import AVKit

/// AppKit AVPlayerView wrapper. SwiftUI's `VideoPlayer` crashes at runtime
/// here: the `_AVKit_SwiftUI` overlay shipped with the CommandLineTools SDK
/// can't initialize its generic class metadata against the installed macOS
/// runtime (SIGABRT in getSuperclassMetadata). Plain ObjC AVPlayerView has
/// no Swift overlay metadata, so it sidesteps the mismatch entirely.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none // custom control bar in StudioView
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}
