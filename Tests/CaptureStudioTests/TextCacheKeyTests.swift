import Testing
import CoreGraphics
@testable import CaptureStudio

/// The compositor caches rendered caption images by `TextCacheKey`, which must
/// capture every block property that changes the rendered pixels. `boxWidth`
/// and `autoWrap` change wrapping (and therefore the pixels), so two blocks
/// differing only in those must NOT collide in the cache — otherwise resizing
/// the wrap box or toggling auto-wrap shows a stale baked image.
@Suite struct TextCacheKeyTests {
    private let canvas = CGSize(width: 100, height: 100)

    @Test func boxWidthDistinguishesKey() {
        var a = TextBlock(begin: 0, end: 1, text: "hi")
        a.boxWidth = 0.9
        var b = a
        b.boxWidth = 0.3
        #expect(StudioCompositor.TextCacheKey(a, canvas: canvas)
                != StudioCompositor.TextCacheKey(b, canvas: canvas))
    }

    @Test func autoWrapDistinguishesKey() {
        var a = TextBlock(begin: 0, end: 1, text: "hi")
        a.autoWrap = true
        var b = a
        b.autoWrap = false
        #expect(StudioCompositor.TextCacheKey(a, canvas: canvas)
                != StudioCompositor.TextCacheKey(b, canvas: canvas))
    }

    @Test func identicalBlocksShareKey() {
        let a = TextBlock(begin: 0, end: 1, text: "hi")
        // Position differs but is excluded from the key (a moved block reuses
        // its render), so the keys must still match.
        var b = a
        b.centerX = 0.1
        b.centerY = 0.2
        #expect(StudioCompositor.TextCacheKey(a, canvas: canvas)
                == StudioCompositor.TextCacheKey(b, canvas: canvas))
    }
}
