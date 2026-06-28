import Testing
import Foundation
@testable import CaptureStudio

@Suite struct EditStateTests {
    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(trimIn: 1.5, trimOut: 8.25)
        try bundle.writeEdit(edit)
        #expect(bundle.loadEdit() == edit)
    }

    @Test func committedTrimRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(committedTrimStart: 2.5, committedTrimEnd: 9.0)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.committedTrimStart == 2.5)
        #expect(loaded.committedTrimEnd == 9.0)
    }

    @Test func missingCommittedTrimDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = bundle.loadEdit()
        #expect(edit.committedTrimStart == 0)
        #expect(edit.committedTrimEnd == nil)
    }

    @Test func missingEditFileYieldsDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = bundle.loadEdit()
        #expect(edit.trimIn == 0)
        #expect(edit.trimOut == nil)
    }

    @Test func volumesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(micVolume: 0.4, systemVolume: 0.75)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.micVolume == 0.4)
        #expect(loaded.systemVolume == 0.75)
    }

    @Test func legacyEditJSONDefaultsVolumesToFull() throws {
        // edit.json written before volume fields existed.
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.micVolume == 1.0)
        #expect(edit.systemVolume == 1.0)
        #expect(edit.trimIn == 2.0)
    }

    @Test func cameraReframeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(cameraZoom: 2.5, cameraFeedX: 0.3, cameraFeedY: 0.7)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.cameraZoom == 2.5)
        #expect(loaded.cameraFeedX == 0.3)
        #expect(loaded.cameraFeedY == 0.7)
    }

    @Test func legacyEditJSONDefaultsCameraReframe() throws {
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraZoom == 1.0)
        #expect(edit.cameraFeedX == 0.5)
        #expect(edit.cameraFeedY == 0.5)
    }

    @Test func cameraStyleRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(cameraShape: .circle, cameraCornerRadius: 0.3,
                             cameraBorderWidth: 0.04, cameraBorderHex: "#FF8800",
                             cameraShadow: true)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.cameraShape == .circle)
        #expect(loaded.cameraCornerRadius == 0.3)
        #expect(loaded.cameraBorderWidth == 0.04)
        #expect(loaded.cameraBorderHex == "#FF8800")
        #expect(loaded.cameraShadow == true)
    }

    @Test func legacyEditJSONDefaultsCameraStyle() throws {
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraShape == .rectangle)
        #expect(edit.cameraCornerRadius == 0)
        #expect(edit.cameraBorderWidth == 0)
        #expect(edit.cameraBorderHex == "#FFFFFF")
        #expect(edit.cameraShadow == false)
    }

    @Test func unknownCameraShapeFallsBackToRectangle() throws {
        let json = #"{"schemaVersion":1,"cameraShape":"hexagon"}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraShape == .rectangle)
    }

    @Test func cameraAspectAndShadowRadiusRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(cameraShadowRadius: 0.8, cameraAspect: .threeByFour)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.cameraShadowRadius == 0.8)
        #expect(loaded.cameraAspect == .threeByFour)
    }

    @Test func cameraRotationRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(cameraRotation: 270)
        try bundle.writeEdit(edit)
        #expect(bundle.loadEdit().cameraRotation == 270)
    }

    @Test func legacyEditJSONDefaultsCameraAspectAndShadowRadius() throws {
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraAspect == .original)
        #expect(edit.cameraShadowRadius == 0.5)
        #expect(edit.cameraRotation == 0)
    }

    @Test func unknownCameraAspectFallsBackToOriginal() throws {
        let json = #"{"schemaVersion":1,"cameraAspect":"21:9"}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraAspect == .original)
    }

    @Test func cropRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let edit = EditState(cropAspect: .nineBySixteen, cropCenterX: 0.3,
                             cropCenterY: 0.6, cropZoom: 0.5)
        try bundle.writeEdit(edit)
        let loaded = bundle.loadEdit()
        #expect(loaded.cropAspect == .nineBySixteen)
        #expect(loaded.cropCenterX == 0.3)
        #expect(loaded.cropCenterY == 0.6)
        #expect(loaded.cropZoom == 0.5)
    }

    @Test func legacyEditJSONDefaultsToNoCrop() throws {
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cropAspect == .original)
        #expect(edit.cropCenterX == 0.5)
        #expect(edit.cropCenterY == 0.5)
        #expect(edit.cropZoom == 1.0)
    }

    @Test func unknownCropAspectFallsBackToOriginal() throws {
        let json = #"{"schemaVersion":1,"cropAspect":"21:9"}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cropAspect == .original)
    }

    @Test func wideAspectsDecode() throws {
        for raw in ["16:9", "4:3"] {
            let json = #"{"schemaVersion":1,"cropAspect":""# + raw + #""}"#
            let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
            #expect(edit.cropAspect.rawValue == raw)
            #expect(edit.cropAspect.ratio! > 1)
        }
    }

    @Test func cropAspectEncodesAsRawString() throws {
        let data = try JSONEncoder().encode(EditState(cropAspect: .square))
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains(#""cropAspect":"1:1""#))
    }

    @Test func nilTrimOutMeansFullLength() throws {
        let data = try JSONEncoder().encode(EditState(trimIn: 0, trimOut: nil))
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("trimOut"))
    }

    @Test func cameraBlocksRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let blocks = [
            CameraBlock(begin: 0, end: 1, layout: .mainAndFloat, centerX: 0.2, centerY: 0.3, scale: 0.25),
            CameraBlock(begin: 4.5, end: 5.2, layout: .cameraStatic, centerX: 0.8, centerY: 0.7, scale: 0.4),
        ]
        let edit = EditState(cameraBlocks: blocks)
        try bundle.writeEdit(edit)
        #expect(bundle.loadEdit().cameraBlocks == blocks)
    }

    @Test func legacyEditJSONDefaultsBlocksEmpty() throws {
        let json = #"{"schemaVersion":1,"trimIn":2.0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraBlocks.isEmpty)
        #expect(edit.cameraHomeLayout == .mainAndFloat)
    }

    @Test func legacyVisibleBlocksMigrateToLayout() throws {
        // A bundle written before layouts: blocks carry `visible`, no `layout`;
        // top-level `cameraVisible:false` → the home becomes main-only.
        let json = #"""
        {"schemaVersion":1,"cameraVisible":false,"cameraBlocks":[
          {"id":"00000000-0000-0000-0000-000000000001","begin":0,"end":1,"visible":true,"centerX":0.2,"centerY":0.3,"scale":0.25},
          {"id":"00000000-0000-0000-0000-000000000002","begin":2,"end":3,"visible":false,"centerX":0.8,"centerY":0.7,"scale":0.4}
        ]}
        """#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraHomeLayout == .mainOnly)
        #expect(edit.cameraBlocks[0].layout == .mainAndFloat)
        #expect(edit.cameraBlocks[1].layout == .mainOnly)
    }

    @Test func legacyVisibleTrueMigratesHomeToMainAndFloat() throws {
        let json = #"{"schemaVersion":1,"cameraVisible":true}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.cameraHomeLayout == .mainAndFloat)
    }

    @Test func subtitlesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = SubtitleTrack(
            srtFilename: "subtitles.srt",
            style: SubtitleStyle(centerY: 0.8, fontSize: 0.07, colorHex: "#FFEE00"),
            cues: [SubtitleCue(begin: 1, end: 2.5, text: "Hello"),
                   SubtitleCue(begin: 3, end: 4, text: "World")])
        var edit = EditState()
        edit.subtitles = track
        try bundle.writeEdit(edit)
        #expect(bundle.loadEdit().subtitles == track)
    }

    @Test func legacyEditJSONHasNilSubtitles() throws {
        let json = #"{"schemaVersion":1,"trimIn":0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.subtitles == nil)
    }

    @Test func subtitleCueMissingIdDecodes() throws {
        let json = #"{"begin":1.0,"end":2.0,"text":"Hi"}"#
        let cue = try JSONDecoder().decode(SubtitleCue.self, from: Data(json.utf8))
        #expect(cue.begin == 1.0 && cue.end == 2.0 && cue.text == "Hi")
    }

    @Test func subtitleOffsetRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = SubtitleTrack(
            srtFilename: "subtitles.srt",
            cues: [SubtitleCue(begin: 1, end: 2, text: "Hi")],
            offset: -2.5)
        var edit = EditState()
        edit.subtitles = track
        try bundle.writeEdit(edit)
        #expect(bundle.loadEdit().subtitles?.offset == -2.5)
    }

    @Test func legacySubtitleTrackHasZeroOffset() throws {
        let json = #"{"srtFilename":"s.srt","style":{},"cues":[{"begin":1,"end":2,"text":"Hi"}]}"#
        let track = try JSONDecoder().decode(SubtitleTrack.self, from: Data(json.utf8))
        #expect(track.offset == 0)
    }

    @Test func subtitleStyleMapsToTextBlock() {
        let style = SubtitleStyle(centerX: 0.4, centerY: 0.7, fontName: "Georgia",
                                  fontSize: 0.08, fontWeight: .bold, colorHex: "#112233",
                                  alignment: .leading, strokeWidth: 0.05, strokeHex: "#445566",
                                  boxEnabled: true, boxHex: "#778899", boxOpacity: 0.6,
                                  shadow: false, boxWidth: 0.55)
        let id = UUID()
        let b = style.asTextBlock(id: id, begin: 1, end: 2, text: "Hi")
        #expect(b.id == id)
        #expect(b.begin == 1 && b.end == 2 && b.text == "Hi")
        #expect(b.centerX == 0.4 && b.centerY == 0.7)
        #expect(b.fontName == "Georgia" && b.fontSize == 0.08 && b.fontWeight == .bold)
        #expect(b.colorHex == "#112233" && b.alignment == .leading)
        #expect(b.strokeWidth == 0.05 && b.strokeHex == "#445566")
        #expect(b.boxEnabled && b.boxHex == "#778899" && b.boxOpacity == 0.6)
        #expect(b.shadow == false)
        // Box width carries through; subtitles always auto-wrap to that width.
        #expect(b.boxWidth == 0.55 && b.autoWrap == true)
    }

    @Test func subtitleStyleBoxWidthRoundTrips() throws {
        let style = SubtitleStyle(boxWidth: 0.6)
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(SubtitleStyle.self, from: data).boxWidth == 0.6)
    }

    @Test func legacySubtitleStyleHasDefaultBoxWidth() throws {
        let json = #"{"centerX":0.5,"centerY":0.85}"#
        let style = try JSONDecoder().decode(SubtitleStyle.self, from: Data(json.utf8))
        #expect(style.boxWidth == 0.9)
    }

    @Test func textBlockNewFieldsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        var tb = TextBlock(begin: 0, end: 2, text: "hi")
        tb.boxWidth = 0.42
        tb.autoWrap = false
        var edit = EditState()
        edit.textBlocks = [tb]
        try bundle.writeEdit(edit)

        let loaded = bundle.loadEdit().textBlocks.first
        #expect(loaded?.boxWidth == 0.42)
        #expect(loaded?.autoWrap == false)
    }

    @Test func textBlockMissingNewFieldsDefault() throws {
        let id = UUID().uuidString
        let json = """
        {"id":"\(id)","begin":0,"end":2,"text":"hi","centerX":0.5,"centerY":0.85,\
        "fontName":"Helvetica","fontSize":0.06,"fontWeight":"semibold","colorHex":"#FFFFFF",\
        "alignment":"center","boxEnabled":false,"boxHex":"#000000","boxOpacity":0.5,\
        "strokeWidth":0,"strokeHex":"#000000","shadow":true,"source":"manual"}
        """.data(using: .utf8)!
        let tb = try JSONDecoder().decode(TextBlock.self, from: json)
        #expect(tb.boxWidth == 0.9)
        #expect(tb.autoWrap == true)
    }

    @Test func zoomBlocksRoundTrip() throws {
        var state = EditState()
        state.zoomBlocks = [
            ZoomBlock(begin: 1, end: 3, scale: 2.5),
            ZoomBlock(begin: 4, end: 6, scale: nil),
        ]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)
        #expect(decoded.zoomBlocks == state.zoomBlocks)
        #expect(decoded.zoomBlocks[1].scale == nil)
    }

    @Test func zoomBlocksDefaultEmptyOnOldBundle() throws {
        // edit.json written before zoomBlocks existed → decodes to [].
        let json = #"{"schemaVersion":1,"trimIn":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditState.self, from: json)
        #expect(decoded.zoomBlocks.isEmpty)
    }

    @Test func layoutBlocksRoundTrip() throws {
        var state = EditState()
        state.layoutBlocks = [
            LayoutBlock(begin: 0, end: 2, layout: .mainOnly),
            LayoutBlock(begin: 4, end: 6, layout: .cameraStatic),
        ]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)
        #expect(decoded.layoutBlocks == state.layoutBlocks)
    }

    @Test func layoutBlocksDefaultEmptyOnOldBundle() throws {
        // edit.json written before layoutBlocks existed → decodes to [].
        let json = #"{"schemaVersion":1,"trimIn":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditState.self, from: json)
        #expect(decoded.layoutBlocks.isEmpty)
    }

    @Test func layoutBlockUnknownLayoutFallsBackToMainAndFloat() throws {
        let json = #"{"layoutBlocks":[{"begin":0,"end":2,"layout":"someFutureMode"}]}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditState.self, from: json)
        #expect(decoded.layoutBlocks.first?.layout == .mainAndFloat)
    }

    @Test func zoomBlockSensitivityRoundTrip() throws {
        var state = EditState()
        state.zoomBlocks = [
            ZoomBlock(begin: 1, end: 3, scale: 2.0, sensitivity: 0.2),
            ZoomBlock(begin: 4, end: 6, scale: nil, sensitivity: nil),
        ]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(EditState.self, from: data)
        #expect(decoded.zoomBlocks == state.zoomBlocks)
        #expect(decoded.zoomBlocks[0].sensitivity == 0.2)
        #expect(decoded.zoomBlocks[1].sensitivity == nil)
    }

    @Test func zoomBlockMissingSensitivityDecodesNil() throws {
        // A zoom block written before `sensitivity` existed (only scale present).
        let json = #"{"zoomBlocks":[{"id":"00000000-0000-0000-0000-000000000000","begin":1,"end":3,"scale":2}]}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditState.self, from: json)
        #expect(decoded.zoomBlocks.count == 1)
        #expect(decoded.zoomBlocks[0].sensitivity == nil)
    }
}
