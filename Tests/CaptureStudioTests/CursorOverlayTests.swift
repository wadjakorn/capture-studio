import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

@Suite struct CursorOverlayTests {
    private func display(originX: Double = 0, originY: Double = 0,
                         pointWidth: Double = 1000, pointHeight: Double = 500) -> DisplayInfo {
        DisplayInfo(displayID: 1, pixelWidth: 2000, pixelHeight: 1000,
                    pointWidth: pointWidth, pointHeight: pointHeight,
                    scaleFactor: 2, originX: originX, originY: originY)
    }

    @Test func mapsScreenPointToSourcePixels() {
        let p = CursorOverlay.sourcePoint(x: 500, y: 250, display: display(),
                                          sourceSize: CGSize(width: 2000, height: 1000))
        #expect(p.x == 1000)
        #expect(p.y == 500)
    }

    @Test func mappingAccountsForDisplayOrigin() {
        let p = CursorOverlay.sourcePoint(x: 600, y: 250, display: display(originX: 100),
                                          sourceSize: CGSize(width: 2000, height: 1000))
        #expect(p.x == 1000) // (600 - 100) / 1000 * 2000
    }

    @Test func extractsAndSortsSamples() {
        let events: [EventLine] = [
            EventLine(t: 1.0, e: .pos, x: 500, y: 250, cursor: "arrow"),
            EventLine(t: 0.5, e: .pos, x: 0, y: 0, cursor: "pointingHand"),
            EventLine(t: 0.8, e: .down, x: 250, y: 0, btn: "left"),
            EventLine(t: 0.9, e: .key, keyCode: 36), // ignored (no x/y, not pos/down)
            EventLine(t: 0.85, e: .up, x: 250, y: 0, btn: "left"), // ignored kind
        ]
        let s = CursorOverlay.samples(from: events, display: display(),
                                      sourceSize: CGSize(width: 2000, height: 1000))
        #expect(s.cursor.count == 2)
        #expect(s.cursor.map(\.t) == [0.5, 1.0]) // sorted
        #expect(s.cursor.first?.cursor == "pointingHand")
        #expect(s.clicks.count == 1)
        #expect(s.clicks.first?.p.x == 500) // 250/1000*2000
    }

    @Test func interpolatesCursorPositionBetweenSamples() {
        let samples = [
            CursorSample(t: 0, p: CGPoint(x: 0, y: 0), cursor: "arrow"),
            CursorSample(t: 1, p: CGPoint(x: 100, y: 200), cursor: "ibeam"),
        ]
        let mid = CursorOverlay.position(at: 0.5, in: samples)
        #expect(mid?.p.x == 50)
        #expect(mid?.p.y == 100)
        #expect(mid?.cursor == "arrow") // name from the earlier sample
    }

    @Test func clampsToEnds() {
        let samples = [
            CursorSample(t: 1, p: CGPoint(x: 10, y: 10), cursor: "arrow"),
            CursorSample(t: 2, p: CGPoint(x: 20, y: 20), cursor: "arrow"),
        ]
        #expect(CursorOverlay.position(at: 0, in: samples)?.p.x == 10)
        #expect(CursorOverlay.position(at: 5, in: samples)?.p.x == 20)
        #expect(CursorOverlay.position(at: 0, in: []) == nil)
    }
}
