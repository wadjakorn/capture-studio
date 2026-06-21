import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

struct CanvasBackgroundTests {
    @Test func defaultsToBlack() {
        #expect(EditState().canvasBackground == .black)
        #expect(EditState().canvasBackgroundBlur == 0.03)
        #expect(EditState().canvasBackgroundImage == nil)
    }

    @Test func decodesKnownAndUnknownRawValues() {
        #expect(CanvasBackground(rawValue: "blur") == .blur)
        #expect(CanvasBackground(rawValue: "image") == .image)
        #expect(CanvasBackground(rawValue: "nope") == nil)   // → EditState falls back to .black
    }

    // edit.json written before these fields still loads with defaults.
    @Test func oldBundleDecodesToBlack() throws {
        let json = #"{"schemaVersion":1,"cropAspect":"9:16 with template"}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.canvasBackground == .black)
        #expect(edit.canvasBackgroundBlur == 0.03)
        #expect(edit.canvasBackgroundImage == nil)
    }

    @Test func roundTripsThroughCodable() throws {
        var edit = EditState()
        edit.canvasBackground = .image
        edit.canvasBackgroundBlur = 0.05
        edit.canvasBackgroundImage = "background.png"
        let data = try JSONEncoder().encode(edit)
        let back = try JSONDecoder().decode(EditState.self, from: data)
        #expect(back.canvasBackground == .image)
        #expect(back.canvasBackgroundBlur == 0.05)
        #expect(back.canvasBackgroundImage == "background.png")
    }

    // Cover-fill: a 16:9 source fills a 9:16 canvas by height, overflow cropped
    // horizontally, centered. (Background photo / blur placement.)
    @Test func aspectFillCoversCanvas() {
        let fill = CropMath.aspectFillRect(CGSize(width: 1920, height: 1080),
                                           in: CGSize(width: 1080, height: 1920))
        #expect(fill.height == 1920)            // fills the long axis
        #expect(fill.width > 1080)              // overflows the short axis
        #expect(fill.minY == 0)                 // flush vertically
        #expect(fill.midX == 540)               // centered horizontally
    }
}
