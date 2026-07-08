import SwiftUI

enum RailTab: String, CaseIterable, Hashable {
    case frame, cursor, camera, text, subtitles, audio

    var symbol: String {
        switch self {
        case .frame:     return "crop"
        case .cursor:    return "cursorarrow"
        case .camera:    return "person.crop.square"
        case .text:      return "textformat"
        case .subtitles: return "captions.bubble"
        case .audio:     return "speaker.wave.2"
        }
    }
    var title: String {
        switch self {
        case .frame:     return "Frame"
        case .cursor:    return "Cursor"
        case .camera:    return "Camera"
        case .text:      return "Text"
        case .subtitles: return "Subtitles"
        case .audio:     return "Audio"
        }
    }
}

/// Plain snapshot of the model's selection flags — keeps context resolution
/// pure and unit-testable.
struct StudioSelectionSummary: Equatable {
    var textSelected = false
    var shapeSelected = false
    var zoomSelected = false
    var cameraMoveSelected = false
    var layoutSelected = false
    var subtitleSelected = false
    /// The camera PiP itself is selected on-canvas (distinct from a
    /// camera-move timeline block).
    var cameraSelected = false
}

/// What the inspector is currently showing.
enum InspectorContext: Equatable {
    case tab(RailTab)
    case shape
    case zoom

    /// Selection wins over the active rail tab. Shape/zoom are contextual;
    /// text selection routes to the Text tab, subtitle to the Subtitles tab;
    /// camera-move/layout under Camera.
    static func resolve(selection s: StudioSelectionSummary,
                        activeTab: RailTab) -> InspectorContext {
        if s.shapeSelected { return .shape }
        if s.zoomSelected { return .zoom }
        if s.textSelected { return .tab(.text) }
        if s.subtitleSelected { return .tab(.subtitles) }
        if s.cameraSelected || s.cameraMoveSelected || s.layoutSelected { return .tab(.camera) }
        return .tab(activeTab)
    }
}
