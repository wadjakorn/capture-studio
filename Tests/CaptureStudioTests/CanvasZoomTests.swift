import Testing
import Foundation
import CoreGraphics
@testable import CaptureStudio

/// Shapes (mask / blur) mark screen content, so they must move with the
/// screen's auto zoom: same mapping as the zoomed video.
@Suite struct CanvasZoomTests {
    @Test func identityLeavesGeometryAlone() {
        let r = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(CanvasZoom.identity.map(r) == r)
        #expect(CanvasZoom(scale: 1, focus: CGPoint(x: 5, y: 5), target: CGPoint(x: 90, y: 90))
            .map(r) == r)
    }

    @Test func mapsPointsAndRectsLikeTheMagnifiedVideo() {
        // 2× about (400, 300), recentred onto (960, 540).
        let z = CanvasZoom(scale: 2, focus: CGPoint(x: 400, y: 300),
                           target: CGPoint(x: 960, y: 540))
        #expect(z.map(CGPoint(x: 400, y: 300)) == CGPoint(x: 960, y: 540))
        #expect(z.map(CGPoint(x: 500, y: 250)) == CGPoint(x: 1160, y: 440))
        #expect(z.map(CGRect(x: 450, y: 280, width: 100, height: 40))
                == CGRect(x: 1060, y: 500, width: 200, height: 80))
    }

    @Test func normalizedMappingAgreesWithPixelMapping() {
        let canvas = CGSize(width: 1920, height: 1080)
        let z = CanvasZoom(scale: 2.5, focus: CGPoint(x: 400, y: 300),
                           target: CGPoint(x: 960, y: 540))
        let p = CGPoint(x: 700, y: 650)
        let px = z.map(p)
        let n = z.normalized(by: canvas).map(CGPoint(x: p.x / canvas.width, y: p.y / canvas.height))
        #expect(abs(n.x * canvas.width - px.x) < 1e-6)
        #expect(abs(n.y * canvas.height - px.y) < 1e-6)
    }

    @Test func compositorMappingMatchesTheTrack() {
        let canvas = CGSize(width: 1920, height: 1080)
        let layout = CompositorLayout(canvas: canvas, sourceSize: canvas, screenTrackID: 1)
        let track = [ZoomKeyframe(t: 0, scale: 1, focusX: 400, focusY: 300),
                     ZoomKeyframe(t: 1, scale: 2, focusX: 400, focusY: 300, weight: 1),
                     ZoomKeyframe(t: 3, scale: 2, focusX: 400, focusY: 300, weight: 1),
                     ZoomKeyframe(t: 4, scale: 1, focusX: 400, focusY: 300)]
        // Outside the track: no zoom.
        #expect(StudioCompositor.canvasZoom(at: 9, track: track, layout: layout).isIdentity)
        #expect(StudioCompositor.canvasZoom(at: 2, track: [], layout: layout).isIdentity)
        // Held: the focus goes to the cover-clamped target, here (480, 300) → x
        // clamped so the 2× picture still covers the canvas.
        let z = StudioCompositor.canvasZoom(at: 2, track: track, layout: layout)
        #expect(z.scale == 2)
        #expect(z.focus == CGPoint(x: 400, y: 300))
        let expected = StudioCompositor.recenterTarget(
            focus: z.focus, weight: 1, scale: 2,
            content: CGRect(origin: .zero, size: canvas),
            region: CGRect(origin: .zero, size: canvas), clamp: true)
        #expect(z.target == expected)
        // A shape drawn over the focus stays over it.
        let shape = CGRect(x: 380, y: 290, width: 40, height: 20)
        let mapped = z.map(shape)
        #expect(abs(mapped.midX - expected.x) < 1e-6)
        #expect(abs(mapped.midY - expected.y) < 1e-6)
    }
}
