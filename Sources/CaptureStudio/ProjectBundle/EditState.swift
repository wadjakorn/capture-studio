import Foundation

/// Output aspect for reframing exports (social clips). `original` means no
/// crop. Stored as the raw string in edit.json; unknown values written by a
/// future version decode as `original`.
enum CropAspect: String, Codable, CaseIterable, Equatable {
    case original
    case nineBySixteen = "9:16"
    case nineBySixteenTemplate = "9:16 with template"
    case square = "1:1"
    case fourByFive = "4:5"
    case sixteenByNine = "16:9"
    case fourByThree = "4:3"

    /// Width / height of the output canvas; nil for `original`.
    var ratio: Double? {
        switch self {
        case .original: return nil
        case .nineBySixteen, .nineBySixteenTemplate: return 9.0 / 16.0
        case .square: return 1.0
        case .fourByFive: return 4.0 / 5.0
        case .sixteenByNine: return 16.0 / 9.0
        case .fourByThree: return 4.0 / 3.0
        }
    }

    /// Contain (fit/letterbox) the source instead of cover (crop). Only the
    /// template aspect fits; every other aspect crops to fill.
    var isFit: Bool { self == .nineBySixteenTemplate }

    var displayName: String {
        self == .original ? "Original" : rawValue
    }
}

/// Background fill behind the fitted video in "9:16 with template" (fit) mode —
/// what shows in the letterbox bars. `black` is the default; `blur` blurs the
/// main video to fill the canvas; `image` shows the uploaded photo (cover-fill).
/// Unknown raw strings (future versions) decode as `black`.
enum CanvasBackground: String, Codable, CaseIterable, Equatable {
    case black, blur, image

    var displayName: String {
        switch self {
        case .black: return "Black"
        case .blur: return "Blur"
        case .image: return "Photo"
        }
    }
}

/// Camera PiP frame shape. Unknown raw strings (future versions) decode as
/// `rectangle`.
enum CameraShape: String, Codable, CaseIterable, Equatable {
    case rectangle
    case circle

    var displayName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .circle: return "Circle"
        }
    }
}

/// Camera feed crop aspect. `original` keeps the camera's native aspect.
/// Unknown raw strings (future versions) decode as `original`.
enum CameraAspect: String, Codable, CaseIterable, Equatable {
    case original
    case square = "1:1"
    case threeByFour = "3:4"
    case fourByThree = "4:3"
    case sixteenByNine = "16:9"
    case nineBySixteen = "9:16"

    /// Width / height of the crop; nil for `original` (use native aspect).
    var ratio: Double? {
        switch self {
        case .original: return nil
        case .square: return 1.0
        case .threeByFour: return 3.0 / 4.0
        case .fourByThree: return 4.0 / 3.0
        case .sixteenByNine: return 16.0 / 9.0
        case .nineBySixteen: return 9.0 / 16.0
        }
    }

    var displayName: String {
        self == .original ? "Original" : rawValue
    }
}

/// The frame composition at a given timestamp — what the layout timeline picks
/// per block (and the static "home" state). Replaces the old binary camera
/// show/hide: instead of just "camera on/off", a block chooses one of four
/// arrangements of the main video and the camera.
enum CameraLayout: String, Codable, CaseIterable, Equatable {
    /// Main video with a floating, moveable camera PiP. The legacy default.
    case mainAndFloat
    /// Main video only — no camera (the old `visible == false`).
    case mainOnly
    /// Floating, moveable camera over the background fill — no main video.
    case floatCamera
    /// Camera centered and enlarged (contain-fit, padded) over the background
    /// fill — no main video. Position/scale are auto-computed.
    case cameraStatic

    /// Whether the main screen video is part of this layout.
    var showsMainVideo: Bool { self == .mainAndFloat || self == .mainOnly }
    /// Whether the camera is drawn in this layout.
    var showsCamera: Bool { self != .mainOnly }
    /// Whether the camera is a moveable floating PiP — gates the move-block
    /// action and the on-canvas position handles.
    var cameraFloats: Bool { self == .mainAndFloat || self == .floatCamera }
    /// Layouts that suppress the main video or full-screen the camera need the
    /// Core Image compositor even with no timeline blocks (the cheap layer-
    /// instruction path can only place a PiP over the unmodified screen).
    var needsCompositor: Bool { self == .floatCamera || self == .cameraStatic }

    var label: String {
        switch self {
        case .mainAndFloat: return "Main + Camera"
        case .mainOnly: return "Main Only"
        case .floatCamera: return "Camera Float"
        case .cameraStatic: return "Camera Static"
        }
    }

    var symbol: String {
        switch self {
        case .mainAndFloat: return "pip"
        case .mainOnly: return "rectangle"
        case .floatCamera: return "person.crop.rectangle"
        case .cameraStatic: return "person.crop.square"
        }
    }
}

/// One layout span on the screen-track timeline. The camera eases from the
/// previous block's settled placement (or the static "home" placement for the
/// first block) into this block's placement over `[begin, end]`, then holds it
/// until the next block. `begin == end` is a hard cut. Blocks never overlap
/// (camera is a single instance). Position/scale match the static
/// `cameraCenterX/Y` / `cameraScale` units (used only by the floating layouts);
/// `layout` picks the frame composition.
struct CameraBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double
    var end: Double
    var layout: CameraLayout
    var centerX: Double
    var centerY: Double
    var scale: Double

    init(id: UUID = UUID(), begin: Double, end: Double,
         layout: CameraLayout = .mainAndFloat,
         centerX: Double, centerY: Double, scale: Double) {
        self.id = id
        self.begin = begin
        self.end = end
        self.layout = layout
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
    }

    enum CodingKeys: String, CodingKey {
        case id, begin, end, layout, visible, centerX, centerY, scale
    }

    /// Migrates legacy bundles: a block written with `visible` (and no `layout`)
    /// decodes to `mainAndFloat` when shown, `mainOnly` when hidden.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        begin = try c.decodeIfPresent(Double.self, forKey: .begin) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        if let lay = try c.decodeIfPresent(CameraLayout.self, forKey: .layout) {
            layout = lay
        } else {
            let visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
            layout = visible ? .mainAndFloat : .mainOnly
        }
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.85
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.82
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 0.24
    }

    /// Writes `layout` plus a legacy `visible` mirror so an older build still
    /// shows/hides the camera roughly correctly.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(begin, forKey: .begin)
        try c.encode(end, forKey: .end)
        try c.encode(layout, forKey: .layout)
        try c.encode(layout.showsCamera, forKey: .visible)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(scale, forKey: .scale)
    }
}

/// One span on the **layout timeline**: over `[begin, end)` the frame uses
/// `layout` (one of the four `CameraLayout` modes). Blocks never overlap (a
/// single layout at a time); the clamps in `LayoutTimeline` enforce this. Time
/// not covered by any block renders blank (solid black) — except when there are
/// no blocks at all, where the static `cameraHomeLayout` applies. Unlike
/// `CameraBlock`, a layout is held flat across its span (categorical, never
/// interpolated); `begin == end` is inert.
struct LayoutBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double
    var end: Double
    var layout: CameraLayout

    init(id: UUID = UUID(), begin: Double, end: Double,
         layout: CameraLayout = .mainAndFloat) {
        self.id = id
        self.begin = begin
        self.end = end
        self.layout = layout
    }

    // Custom decode so a block missing newer fields (or carrying an unknown
    // future layout value) still loads, mirroring the other block types.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        begin = try c.decodeIfPresent(Double.self, forKey: .begin) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        // Raw-string decode so an unknown future layout degrades to the default
        // rather than failing the whole bundle load.
        let layoutRaw = try c.decodeIfPresent(String.self, forKey: .layout)
        layout = layoutRaw.flatMap(CameraLayout.init(rawValue:)) ?? .mainAndFloat
    }
}

/// How a zoom block frames the source. `.follow` pans to track the cursor (the
/// default and legacy behavior); `.manual` holds a fixed frame at the block's
/// `focusX`/`focusY`, ignoring the cursor. Unknown raw strings (future versions)
/// decode as `.follow`.
enum ZoomMode: String, Codable {
    case follow, manual

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ZoomMode(rawValue: raw) ?? .follow
    }
}

/// One auto-zoom span on the screen-track timeline. During `[begin, end)` the
/// canvas zooms in and either pans to follow the cursor or holds a fixed manual
/// frame (see `AutoZoomTrack`, `mode`). Blocks never overlap (a single zoom state
/// at a time), mirroring `CameraBlock`. Adjacent (touching) blocks form one
/// continuous zoom "run" — the zoom holds across their shared boundary instead of
/// dropping to 1×, so follow↔manual can be switched mid-zoom seamlessly. `scale`
/// is the target magnification (≥1); nil means use the global default
/// (`autoZoomDefaultScale`).
struct ZoomBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double
    var end: Double
    var scale: Double?
    /// How aggressively auto-zoom pans toward the cursor (0 = calm / ignore
    /// small moves, 1 = snappy). nil = use the global default
    /// (`autoZoomDefaultSensitivity`). Mirrors `scale`'s override semantics.
    var sensitivity: Double?
    /// When true the zoom may pan the main video past the framing window and off
    /// the canvas edges, revealing the configured background where the video no
    /// longer covers (cursor centred on the canvas). When false/nil the video
    /// stays contained: the pan is clamped so it always fills the framing window
    /// (cursor centred within the window). nil decodes as false (back-compat).
    var overflow: Bool?
    /// Framing mode. nil decodes as `.follow` (back-compat: legacy blocks are all
    /// cursor-follow).
    var mode: ZoomMode?
    /// Manual target focus as a fraction (0…1) of the source width/height, used
    /// only when `mode == .manual`. nil when following the cursor. Stored
    /// normalized so it survives source-dimension / crop changes; converted to
    /// source pixels at build time.
    var focusX: Double?
    var focusY: Double?

    init(id: UUID = UUID(), begin: Double, end: Double, scale: Double? = nil,
         sensitivity: Double? = nil, overflow: Bool? = nil,
         mode: ZoomMode? = nil, focusX: Double? = nil, focusY: Double? = nil) {
        self.id = id
        self.begin = begin
        self.end = end
        self.scale = scale
        self.sensitivity = sensitivity
        self.overflow = overflow
        self.mode = mode
        self.focusX = focusX
        self.focusY = focusY
    }
}

/// Text/caption font weight. Unknown raw strings (future versions) decode as
/// `semibold`.
enum TextWeight: String, Codable, CaseIterable, Equatable {
    case regular, medium, semibold, bold

    var displayName: String {
        switch self {
        case .regular: return "Regular"
        case .medium: return "Medium"
        case .semibold: return "Semibold"
        case .bold: return "Bold"
        }
    }
}

/// Horizontal text alignment within a multi-line block. Unknown raw strings
/// (future versions) decode as `center`.
enum TextAlignmentH: String, Codable, CaseIterable, Equatable {
    case leading, center, trailing
}

/// Where a text block came from. `manual` is hand-authored; the others are
/// reserved for the auto-caption feature so generated lines drop into the same
/// model. Unknown raw strings (future versions) decode as `manual`.
enum TextSource: String, Codable, CaseIterable, Equatable {
    case manual, systemAudio, microphone
}

/// One on-screen text/caption instance with a `[begin, end)` span. Unlike
/// `CameraBlock`, text blocks MAY overlap in time — many can be active at once —
/// and there is no single-instance constraint. Z-order is the array order in
/// `EditState.textBlocks` (a later element draws on top). Position is the text
/// center, normalized 0–1 in render space (top-left origin), matching the
/// camera placement units. `fontSize` is a fraction of the canvas HEIGHT and
/// `strokeWidth` a fraction of `fontSize`, so a block looks identical at preview
/// size and full export resolution. `begin == end` is inert (never rendered).
struct TextBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double
    var end: Double
    var text: String
    var centerX: Double
    var centerY: Double
    // Style.
    var fontName: String
    var fontSize: Double
    var fontWeight: TextWeight
    var colorHex: String
    var alignment: TextAlignmentH
    var boxEnabled: Bool
    var boxHex: String
    var boxOpacity: Double
    var strokeWidth: Double
    var strokeHex: String
    var shadow: Bool
    /// Wrap-frame width as a fraction of canvas width. Text soft-wraps to this
    /// width when `autoWrap` is on; ignored when off. 0.9 reproduces the legacy
    /// hardcoded wrap width.
    var boxWidth: Double
    /// When true, text soft-wraps to `boxWidth`; when false only explicit
    /// newlines break lines (long lines extend past the canvas edges).
    var autoWrap: Bool
    // Forward-compat: distinguishes hand-authored vs. auto-generated captions.
    var source: TextSource

    init(id: UUID = UUID(), begin: Double, end: Double, text: String = "",
         centerX: Double = 0.5, centerY: Double = 0.85,
         fontName: String = "Helvetica", fontSize: Double = 0.06,
         fontWeight: TextWeight = .semibold, colorHex: String = "#FFFFFF",
         alignment: TextAlignmentH = .center, boxEnabled: Bool = false,
         boxHex: String = "#000000", boxOpacity: Double = 0.5,
         strokeWidth: Double = 0, strokeHex: String = "#000000",
         shadow: Bool = true, boxWidth: Double = 0.9, autoWrap: Bool = true,
         source: TextSource = .manual) {
        self.id = id
        self.begin = begin
        self.end = end
        self.text = text
        self.centerX = centerX
        self.centerY = centerY
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.colorHex = colorHex
        self.alignment = alignment
        self.boxEnabled = boxEnabled
        self.boxHex = boxHex
        self.boxOpacity = boxOpacity
        self.strokeWidth = strokeWidth
        self.strokeHex = strokeHex
        self.shadow = shadow
        self.boxWidth = boxWidth
        self.autoWrap = autoWrap
        self.source = source
    }

    /// An empty 3 s block at `atTime`, clamped to the clip, centered lower-third.
    static func makeDefault(at atTime: Double, duration: Double) -> TextBlock {
        let begin = min(max(0, atTime), max(0, duration))
        let end = min(begin + 3, max(begin, duration))
        return TextBlock(begin: begin, end: end)
    }

    // Custom decode so bundles missing newer fields (or carrying an unknown
    // future enum value) still load with sensible defaults, mirroring EditState.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        begin = try c.decodeIfPresent(Double.self, forKey: .begin) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.85
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0.06
        let weightRaw = try c.decodeIfPresent(String.self, forKey: .fontWeight)
        fontWeight = weightRaw.flatMap(TextWeight.init(rawValue:)) ?? .semibold
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
        let alignRaw = try c.decodeIfPresent(String.self, forKey: .alignment)
        alignment = alignRaw.flatMap(TextAlignmentH.init(rawValue:)) ?? .center
        boxEnabled = try c.decodeIfPresent(Bool.self, forKey: .boxEnabled) ?? false
        boxHex = try c.decodeIfPresent(String.self, forKey: .boxHex) ?? "#000000"
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? 0.5
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0
        strokeHex = try c.decodeIfPresent(String.self, forKey: .strokeHex) ?? "#000000"
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
        boxWidth = try c.decodeIfPresent(Double.self, forKey: .boxWidth) ?? 0.9
        autoWrap = try c.decodeIfPresent(Bool.self, forKey: .autoWrap) ?? true
        let sourceRaw = try c.decodeIfPresent(String.self, forKey: .source)
        source = sourceRaw.flatMap(TextSource.init(rawValue:)) ?? .manual
    }
}

/// Kind of on-canvas shape overlay. `rectangle` / `ellipse` are drawn outlines
/// or fills; `blur` censors the underlying content in its rect. Unknown raw
/// strings (future versions) decode as `rectangle`.
enum ShapeKind: String, Codable, CaseIterable, Equatable {
    case rectangle, ellipse, blur

    var displayName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .blur: return "Blur"
        }
    }
}

/// How a `blur` shape obscures its region. `gaussian` softens; `pixellate`
/// mosaics. Unknown raw strings (future versions) decode as `gaussian`.
enum ShapeBlurStyle: String, Codable, CaseIterable, Equatable {
    case gaussian, pixellate

    var displayName: String {
        switch self {
        case .gaussian: return "Gaussian"
        case .pixellate: return "Pixellate"
        }
    }
}

/// One on-screen shape overlay with a `[begin, end)` span. Like `TextBlock` (and
/// unlike `CameraBlock`), shapes MAY overlap in time — many can be active at
/// once — and there is no single-instance constraint. Z-order is the array order
/// in `EditState.shapeBlocks` (a later element draws on top). Geometry is
/// normalized 0–1 in render space (top-left origin), matching the camera / text
/// placement units: `centerX`/`centerY` is the shape center; `width`/`height`
/// are fractions of the canvas width / height, so a shape looks identical at
/// preview size and full export resolution. `strokeWidth` is a fraction of the
/// canvas height; `cornerRadius` a fraction of the shape's shorter side (only
/// meaningful for `rectangle`); `blurStrength` a fraction of the canvas height
/// (only meaningful for `blur`). `begin == end` is inert (never rendered).
struct ShapeBlock: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double
    var end: Double
    var kind: ShapeKind
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
    // Style (rectangle / ellipse).
    var fillHex: String
    var fillOpacity: Double
    var strokeHex: String
    var strokeWidth: Double
    /// Corner radius as a fraction of the shape's shorter side (0…0.5).
    /// Rectangle only; ignored for ellipse / blur.
    var cornerRadius: Double
    // Style (blur).
    var blurStyle: ShapeBlurStyle
    /// Blur/pixellate strength as a fraction of the canvas height. Blur only.
    var blurStrength: Double

    init(id: UUID = UUID(), begin: Double, end: Double,
         kind: ShapeKind = .rectangle,
         centerX: Double = 0.5, centerY: Double = 0.5,
         width: Double = 0.3, height: Double = 0.2,
         fillHex: String = "#000000", fillOpacity: Double = 0,
         strokeHex: String = "#FF3B30", strokeWidth: Double = 0.008,
         cornerRadius: Double = 0,
         blurStyle: ShapeBlurStyle = .gaussian, blurStrength: Double = 0.04) {
        self.id = id
        self.begin = begin
        self.end = end
        self.kind = kind
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.fillHex = fillHex
        self.fillOpacity = fillOpacity
        self.strokeHex = strokeHex
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        self.blurStyle = blurStyle
        self.blurStrength = blurStrength
    }

    /// A 3 s block at `atTime`, clamped to the clip, centered.
    static func makeDefault(at atTime: Double, duration: Double,
                            kind: ShapeKind = .rectangle) -> ShapeBlock {
        let begin = min(max(0, atTime), max(0, duration))
        let end = min(begin + 3, max(begin, duration))
        return ShapeBlock(begin: begin, end: end, kind: kind)
    }

    // Custom decode so bundles missing newer fields (or carrying an unknown
    // future enum value) still load with sensible defaults, mirroring TextBlock.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        begin = try c.decodeIfPresent(Double.self, forKey: .begin) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        let kindRaw = try c.decodeIfPresent(String.self, forKey: .kind)
        kind = kindRaw.flatMap(ShapeKind.init(rawValue:)) ?? .rectangle
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.5
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.3
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.2
        fillHex = try c.decodeIfPresent(String.self, forKey: .fillHex) ?? "#000000"
        fillOpacity = try c.decodeIfPresent(Double.self, forKey: .fillOpacity) ?? 0
        strokeHex = try c.decodeIfPresent(String.self, forKey: .strokeHex) ?? "#FF3B30"
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0.008
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        let blurRaw = try c.decodeIfPresent(String.self, forKey: .blurStyle)
        blurStyle = blurRaw.flatMap(ShapeBlurStyle.init(rawValue:)) ?? .gaussian
        blurStrength = try c.decodeIfPresent(Double.self, forKey: .blurStrength) ?? 0.04
    }
}

/// One subtitle cue parsed from an `.srt`: a `[begin, end)` span and read-only
/// text. Unlike `TextBlock`, a cue carries no style — the whole subtitle track
/// shares one `SubtitleStyle`.
struct SubtitleCue: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double
    var end: Double
    var text: String

    init(id: UUID = UUID(), begin: Double, end: Double, text: String) {
        self.id = id
        self.begin = begin
        self.end = end
        self.text = text
    }

    // Custom decode so cue JSON missing "id" (e.g. from an older writer) gets a
    // fresh UUID rather than throwing keyNotFound, mirroring TextBlock / EditState.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        begin = try c.decodeIfPresent(Double.self, forKey: .begin) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

/// The one shared, user-configured look for every subtitle cue. Fields mirror
/// `TextBlock` styling so the existing `TextImageRenderer` renders cues unchanged
/// via `asTextBlock`. Position is normalized 0–1 in render space (top-left
/// origin); `fontSize` is a fraction of canvas height.
struct SubtitleStyle: Codable, Equatable {
    var centerX: Double
    var centerY: Double
    var fontName: String
    // 0.05 is intentionally smaller than TextBlock's 0.06 — subtitles sit
    // closer to the edge and look best slightly smaller; not a typo.
    var fontSize: Double
    var fontWeight: TextWeight
    var colorHex: String
    var alignment: TextAlignmentH
    var strokeWidth: Double
    var strokeHex: String
    var boxEnabled: Bool
    var boxHex: String
    var boxOpacity: Double
    var shadow: Bool
    /// Wrap width as a fraction of canvas width — subtitles always auto-wrap to
    /// it (mirrors `TextBlock.boxWidth`). 0.9 reproduces the prior fixed width.
    var boxWidth: Double

    init(centerX: Double = 0.5, centerY: Double = 0.85,
         fontName: String = "Helvetica", fontSize: Double = 0.05,
         fontWeight: TextWeight = .semibold, colorHex: String = "#FFFFFF",
         alignment: TextAlignmentH = .center, strokeWidth: Double = 0,
         strokeHex: String = "#000000", boxEnabled: Bool = false,
         boxHex: String = "#000000", boxOpacity: Double = 0.5,
         shadow: Bool = true, boxWidth: Double = 0.9) {
        self.centerX = centerX
        self.centerY = centerY
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.colorHex = colorHex
        self.alignment = alignment
        self.strokeWidth = strokeWidth
        self.strokeHex = strokeHex
        self.boxEnabled = boxEnabled
        self.boxHex = boxHex
        self.boxOpacity = boxOpacity
        self.shadow = shadow
        self.boxWidth = boxWidth
    }

    // Custom decode so a track written by an older/newer in-between version with
    // a missing field still loads, mirroring TextBlock / EditState.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.85
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0.05
        let weightRaw = try c.decodeIfPresent(String.self, forKey: .fontWeight)
        fontWeight = weightRaw.flatMap(TextWeight.init(rawValue:)) ?? .semibold
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
        let alignRaw = try c.decodeIfPresent(String.self, forKey: .alignment)
        alignment = alignRaw.flatMap(TextAlignmentH.init(rawValue:)) ?? .center
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0
        strokeHex = try c.decodeIfPresent(String.self, forKey: .strokeHex) ?? "#000000"
        boxEnabled = try c.decodeIfPresent(Bool.self, forKey: .boxEnabled) ?? false
        boxHex = try c.decodeIfPresent(String.self, forKey: .boxHex) ?? "#000000"
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? 0.5
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
        boxWidth = try c.decodeIfPresent(Double.self, forKey: .boxWidth) ?? 0.9
    }

    /// Synthesize a transient `TextBlock` for one cue so the existing renderer /
    /// compositor text path draws it unchanged. `source` is `.manual` (cues are
    /// never auto-captions).
    func asTextBlock(id: UUID, begin: Double, end: Double, text: String) -> TextBlock {
        TextBlock(id: id, begin: begin, end: end, text: text,
                  centerX: centerX, centerY: centerY,
                  fontName: fontName, fontSize: fontSize, fontWeight: fontWeight,
                  colorHex: colorHex, alignment: alignment, boxEnabled: boxEnabled,
                  boxHex: boxHex, boxOpacity: boxOpacity, strokeWidth: strokeWidth,
                  strokeHex: strokeHex, shadow: shadow, boxWidth: boxWidth,
                  autoWrap: true, source: .manual)
    }
}

/// An imported subtitle track: the bundled `.srt` filename, the one shared style,
/// and the read-only cues. Persisted on `EditState`; nil = no subtitles.
struct SubtitleTrack: Codable, Equatable {
    var srtFilename: String
    var style: SubtitleStyle
    var cues: [SubtitleCue]
    var offset: Double           // seconds, added to every cue's begin/end (re-sync)

    init(srtFilename: String, style: SubtitleStyle = SubtitleStyle(),
         cues: [SubtitleCue] = [], offset: Double = 0) {
        self.srtFilename = srtFilename
        self.style = style
        self.cues = cues
        self.offset = offset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        srtFilename = try c.decodeIfPresent(String.self, forKey: .srtFilename) ?? ""
        style = try c.decodeIfPresent(SubtitleStyle.self, forKey: .style) ?? SubtitleStyle()
        cues = try c.decodeIfPresent([SubtitleCue].self, forKey: .cues) ?? []
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
    }
}

/// Studio edit state persisted as edit.json inside the bundle.
/// All edits are metadata — master files are never mutated.
struct EditState: Codable, Equatable {
    var schemaVersion: Int = 1
    /// Trim in-point, seconds on the (already-committed) studio timeline. These
    /// are the live, reversible export markers — distinct from the committed cut
    /// below.
    var trimIn: Double = 0
    /// Trim out-point; nil means end of the timeline.
    var trimOut: Double?
    /// Committed trim window, absolute seconds in the master source. The studio
    /// timeline is the masters cut to `[committedTrimStart, committedTrimEnd)`:
    /// the loader re-derives the trimmed composition from these and every block
    /// below is stored relative to `committedTrimStart` (t = 0). `committedTrimEnd
    /// == nil` means "to the master end". Default 0 / nil = no committed trim, so
    /// legacy bundles (blocks in absolute source time) load unchanged. Applying a
    /// trim (TrimTimeline.apply) narrows this window and rebases the blocks.
    var committedTrimStart: Double = 0
    var committedTrimEnd: Double? = nil
    /// Camera PiP overlay. Position is the PiP center, normalized 0–1 in
    /// render space (top-left origin); scale is PiP width as a fraction of
    /// the screen width.
    var cameraVisible: Bool = true
    /// The layout used before the first timeline block (and when the timeline is
    /// empty). Legacy bundles without this field derive it from `cameraVisible`.
    var cameraHomeLayout: CameraLayout = .mainAndFloat
    var cameraCenterX: Double = 0.85
    var cameraCenterY: Double = 0.82
    var cameraScale: Double = 0.24
    /// Camera feed reframe. Zoom is the crop tightness (1 = whole feed,
    /// >1 zooms in; clamp 1…4); feed center is normalized 0–1 in the camera
    /// feed's own space.
    var cameraZoom: Double = 1.0
    var cameraFeedX: Double = 0.5
    var cameraFeedY: Double = 0.5
    /// Camera PiP frame styling. Corner radius and border width are fractions
    /// of the PiP's shorter side / width; border color is "#RRGGBB".
    var cameraShape: CameraShape = .rectangle
    var cameraCornerRadius: Double = 0
    var cameraBorderWidth: Double = 0
    var cameraBorderHex: String = "#FFFFFF"
    var cameraShadow: Bool = false
    /// Shadow intensity 0–1 (scales blur/offset/opacity together).
    var cameraShadowRadius: Double = 0.5
    /// Camera feed crop aspect; `original` keeps the native aspect.
    var cameraAspect: CameraAspect = .original
    /// Camera orientation, degrees clockwise: 0/90/180/270. Corrects a sideways
    /// or portrait-mounted camera. At 90/270 the feed's width/height swap.
    var cameraRotation: Int = 0
    /// Per-source playback/export volume. System is 0–1 (attenuation). Mic is
    /// 0–3: values >1 boost gain for quiet voice. Older bundles (mic ≤ 1) load
    /// unchanged.
    var micVolume: Double = 1.0
    var systemVolume: Double = 1.0
    /// Cursor + click overlays composited from events.jsonl at render time
    /// (screen.mp4 has no baked cursor). Cursor defaults on; click feedback off.
    /// Bundles written before these fields decode as on/off respectively.
    var showCursor: Bool = true
    var clickFeedback: Bool = false
    /// Reframe crop. Center is normalized 0–1 in screen-source space; zoom is
    /// the crop size as a fraction of the largest crop of that aspect that
    /// fits the source (1.0 = widest).
    var cropAspect: CropAspect = .original
    var cropCenterX: Double = 0.5
    var cropCenterY: Double = 0.5
    var cropZoom: Double = 1.0
    /// Background behind the fitted video in template/fit mode (letterbox bars).
    /// `canvasBackgroundBlur` is the blur radius as a fraction of canvas width;
    /// `canvasBackgroundImage` is the photo's file name inside the bundle (nil =
    /// none). Bundles written before these fields decode as black / 0.03 / nil.
    var canvasBackground: CanvasBackground = .black
    var canvasBackgroundBlur: Double = 0.03
    var canvasBackgroundImage: String? = nil
    /// Camera timeline. Empty = static placement (the `camera*` fields above
    /// drive everything, exactly as before, and serve as the "home" placement).
    /// Non-empty = blocks drive position/scale/visibility over time, easing
    /// from home / the previous block into each block over its span.
    var cameraBlocks: [CameraBlock] = []
    /// On-screen text/caption blocks. Empty = no text. Blocks MAY overlap in
    /// time (unlike `cameraBlocks`); render / z-order is the array order here
    /// (later element = on top), so this is never re-sorted on store.
    var textBlocks: [TextBlock] = []
    /// On-screen shape overlays (rectangle / ellipse / blur). Empty = no shapes.
    /// Blocks MAY overlap in time (like `textBlocks`); render / z-order is the
    /// array order here (later element = on top), so this is never re-sorted.
    var shapeBlocks: [ShapeBlock] = []
    /// Imported subtitle track (nil = none). Cues are read-only; `style` is the
    /// shared look. The `.srt` itself lives in the bundle (see ProjectBundle).
    var subtitles: SubtitleTrack? = nil
    /// Auto-zoom blocks. Empty = no auto zoom/pan. Non-overlapping; during each
    /// block the canvas zooms + pans to follow the cursor.
    var zoomBlocks: [ZoomBlock] = []
    /// Layout timeline. Empty = the whole clip uses `cameraHomeLayout`. Non-empty
    /// = each block sets the frame layout over its span; uncovered gaps render
    /// blank (black). Non-overlapping (a single layout at a time).
    var layoutBlocks: [LayoutBlock] = []
    /// Framing window: a single static rectangle (normalized 0–1 canvas coords,
    /// center + size, top-left origin) that masks the main screen video for the
    /// whole timeline. The video pans behind it via auto zoom; texts, subtitles
    /// and camera are never clipped. Off by default; the background fill shows
    /// outside the window.
    var frameEnabled: Bool = false
    var frameCenterX: Double = 0.5
    var frameCenterY: Double = 0.5
    var frameWidth: Double = 0.6
    var frameHeight: Double = 0.6

    init(trimIn: Double = 0, trimOut: Double? = nil,
         committedTrimStart: Double = 0, committedTrimEnd: Double? = nil,
         cameraVisible: Bool = true,
         cameraHomeLayout: CameraLayout = .mainAndFloat,
         cameraCenterX: Double = 0.85,
         cameraCenterY: Double = 0.82, cameraScale: Double = 0.24,
         cameraZoom: Double = 1.0, cameraFeedX: Double = 0.5,
         cameraFeedY: Double = 0.5,
         cameraShape: CameraShape = .rectangle, cameraCornerRadius: Double = 0,
         cameraBorderWidth: Double = 0, cameraBorderHex: String = "#FFFFFF",
         cameraShadow: Bool = false, cameraShadowRadius: Double = 0.5,
         cameraAspect: CameraAspect = .original, cameraRotation: Int = 0,
         micVolume: Double = 1.0, systemVolume: Double = 1.0,
         showCursor: Bool = true, clickFeedback: Bool = false,
         cropAspect: CropAspect = .original, cropCenterX: Double = 0.5,
         cropCenterY: Double = 0.5, cropZoom: Double = 1.0,
         canvasBackground: CanvasBackground = .black,
         canvasBackgroundBlur: Double = 0.03,
         canvasBackgroundImage: String? = nil,
         cameraBlocks: [CameraBlock] = [], textBlocks: [TextBlock] = [],
         shapeBlocks: [ShapeBlock] = [],
         subtitles: SubtitleTrack? = nil,
         zoomBlocks: [ZoomBlock] = [], layoutBlocks: [LayoutBlock] = [],
         frameEnabled: Bool = false, frameCenterX: Double = 0.5,
         frameCenterY: Double = 0.5, frameWidth: Double = 0.6,
         frameHeight: Double = 0.6) {
        self.trimIn = trimIn
        self.trimOut = trimOut
        self.committedTrimStart = committedTrimStart
        self.committedTrimEnd = committedTrimEnd
        self.cameraVisible = cameraVisible
        self.cameraHomeLayout = cameraHomeLayout
        self.cameraCenterX = cameraCenterX
        self.cameraCenterY = cameraCenterY
        self.cameraScale = cameraScale
        self.cameraZoom = cameraZoom
        self.cameraFeedX = cameraFeedX
        self.cameraFeedY = cameraFeedY
        self.cameraShape = cameraShape
        self.cameraCornerRadius = cameraCornerRadius
        self.cameraBorderWidth = cameraBorderWidth
        self.cameraBorderHex = cameraBorderHex
        self.cameraShadow = cameraShadow
        self.cameraShadowRadius = cameraShadowRadius
        self.cameraAspect = cameraAspect
        self.cameraRotation = cameraRotation
        self.micVolume = micVolume
        self.systemVolume = systemVolume
        self.showCursor = showCursor
        self.clickFeedback = clickFeedback
        self.cropAspect = cropAspect
        self.cropCenterX = cropCenterX
        self.cropCenterY = cropCenterY
        self.cropZoom = cropZoom
        self.canvasBackground = canvasBackground
        self.canvasBackgroundBlur = canvasBackgroundBlur
        self.canvasBackgroundImage = canvasBackgroundImage
        self.cameraBlocks = cameraBlocks
        self.textBlocks = textBlocks
        self.shapeBlocks = shapeBlocks
        self.subtitles = subtitles
        self.zoomBlocks = zoomBlocks
        self.layoutBlocks = layoutBlocks
        self.frameEnabled = frameEnabled
        self.frameCenterX = frameCenterX
        self.frameCenterY = frameCenterY
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }

    // Custom decode so edit.json files written before these fields existed
    // still load with defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        trimIn = try c.decodeIfPresent(Double.self, forKey: .trimIn) ?? 0
        trimOut = try c.decodeIfPresent(Double.self, forKey: .trimOut)
        committedTrimStart = try c.decodeIfPresent(Double.self, forKey: .committedTrimStart) ?? 0
        committedTrimEnd = try c.decodeIfPresent(Double.self, forKey: .committedTrimEnd)
        cameraVisible = try c.decodeIfPresent(Bool.self, forKey: .cameraVisible) ?? true
        if let home = try c.decodeIfPresent(CameraLayout.self, forKey: .cameraHomeLayout) {
            cameraHomeLayout = home
        } else {
            cameraHomeLayout = cameraVisible ? .mainAndFloat : .mainOnly
        }
        cameraCenterX = try c.decodeIfPresent(Double.self, forKey: .cameraCenterX) ?? 0.85
        cameraCenterY = try c.decodeIfPresent(Double.self, forKey: .cameraCenterY) ?? 0.82
        cameraScale = try c.decodeIfPresent(Double.self, forKey: .cameraScale) ?? 0.24
        cameraZoom = try c.decodeIfPresent(Double.self, forKey: .cameraZoom) ?? 1.0
        cameraFeedX = try c.decodeIfPresent(Double.self, forKey: .cameraFeedX) ?? 0.5
        cameraFeedY = try c.decodeIfPresent(Double.self, forKey: .cameraFeedY) ?? 0.5
        let shapeRaw = try c.decodeIfPresent(String.self, forKey: .cameraShape)
        cameraShape = shapeRaw.flatMap(CameraShape.init(rawValue:)) ?? .rectangle
        cameraCornerRadius = try c.decodeIfPresent(Double.self, forKey: .cameraCornerRadius) ?? 0
        cameraBorderWidth = try c.decodeIfPresent(Double.self, forKey: .cameraBorderWidth) ?? 0
        cameraBorderHex = try c.decodeIfPresent(String.self, forKey: .cameraBorderHex) ?? "#FFFFFF"
        cameraShadow = try c.decodeIfPresent(Bool.self, forKey: .cameraShadow) ?? false
        cameraShadowRadius = try c.decodeIfPresent(Double.self, forKey: .cameraShadowRadius) ?? 0.5
        let camAspectRaw = try c.decodeIfPresent(String.self, forKey: .cameraAspect)
        cameraAspect = camAspectRaw.flatMap(CameraAspect.init(rawValue:)) ?? .original
        cameraRotation = try c.decodeIfPresent(Int.self, forKey: .cameraRotation) ?? 0
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1.0
        systemVolume = try c.decodeIfPresent(Double.self, forKey: .systemVolume) ?? 1.0
        showCursor = try c.decodeIfPresent(Bool.self, forKey: .showCursor) ?? true
        clickFeedback = try c.decodeIfPresent(Bool.self, forKey: .clickFeedback) ?? false
        // Raw-string decode so an unknown future aspect degrades to no crop.
        let aspectRaw = try c.decodeIfPresent(String.self, forKey: .cropAspect)
        cropAspect = aspectRaw.flatMap(CropAspect.init(rawValue:)) ?? .original
        cropCenterX = try c.decodeIfPresent(Double.self, forKey: .cropCenterX) ?? 0.5
        cropCenterY = try c.decodeIfPresent(Double.self, forKey: .cropCenterY) ?? 0.5
        cropZoom = try c.decodeIfPresent(Double.self, forKey: .cropZoom) ?? 1.0
        let bgRaw = try c.decodeIfPresent(String.self, forKey: .canvasBackground)
        canvasBackground = bgRaw.flatMap(CanvasBackground.init(rawValue:)) ?? .black
        canvasBackgroundBlur = try c.decodeIfPresent(Double.self, forKey: .canvasBackgroundBlur) ?? 0.03
        canvasBackgroundImage = try c.decodeIfPresent(String.self, forKey: .canvasBackgroundImage)
        cameraBlocks = try c.decodeIfPresent([CameraBlock].self, forKey: .cameraBlocks) ?? []
        textBlocks = try c.decodeIfPresent([TextBlock].self, forKey: .textBlocks) ?? []
        shapeBlocks = try c.decodeIfPresent([ShapeBlock].self, forKey: .shapeBlocks) ?? []
        subtitles = try c.decodeIfPresent(SubtitleTrack.self, forKey: .subtitles)
        zoomBlocks = try c.decodeIfPresent([ZoomBlock].self, forKey: .zoomBlocks) ?? []
        layoutBlocks = try c.decodeIfPresent([LayoutBlock].self, forKey: .layoutBlocks) ?? []
        frameEnabled = try c.decodeIfPresent(Bool.self, forKey: .frameEnabled) ?? false
        frameCenterX = try c.decodeIfPresent(Double.self, forKey: .frameCenterX) ?? 0.5
        frameCenterY = try c.decodeIfPresent(Double.self, forKey: .frameCenterY) ?? 0.5
        frameWidth = try c.decodeIfPresent(Double.self, forKey: .frameWidth) ?? 0.6
        frameHeight = try c.decodeIfPresent(Double.self, forKey: .frameHeight) ?? 0.6
    }
}

extension ProjectBundle {
    func writeEdit(_ edit: EditState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(edit).write(to: editURL, options: .atomic)
    }

    func loadEdit() -> EditState {
        guard let data = try? Data(contentsOf: editURL),
              let edit = try? JSONDecoder().decode(EditState.self, from: data) else {
            return EditState()
        }
        return edit
    }
}
