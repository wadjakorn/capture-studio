import SwiftUI

enum RailTab: String, CaseIterable, Hashable {
    case frame, cursor, camera, captions, audio, shortcuts, share

    var symbol: String {
        switch self {
        case .frame:     return "crop"
        case .cursor:    return "cursorarrow"
        case .camera:    return "person.crop.square"
        case .captions:  return "captions.bubble"
        case .audio:     return "speaker.wave.2"
        case .shortcuts: return "command"
        case .share:     return "square.and.arrow.up"
        }
    }
    var title: String {
        switch self {
        case .frame:     return "Frame"
        case .cursor:    return "Cursor"
        case .camera:    return "Camera"
        case .captions:  return "Captions"
        case .audio:     return "Audio"
        case .shortcuts: return "Shortcuts"
        case .share:     return "Share"
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
}

/// What the inspector is currently showing.
enum InspectorContext: Equatable {
    case tab(RailTab)
    case shape
    case zoom

    /// Selection wins over the active rail tab. Shape/zoom are contextual;
    /// text/subtitle live under Captions; camera-move/layout under Camera.
    static func resolve(selection s: StudioSelectionSummary,
                        activeTab: RailTab) -> InspectorContext {
        if s.shapeSelected { return .shape }
        if s.zoomSelected { return .zoom }
        if s.textSelected || s.subtitleSelected { return .tab(.captions) }
        if s.cameraMoveSelected || s.layoutSelected { return .tab(.camera) }
        return .tab(activeTab)
    }
}
