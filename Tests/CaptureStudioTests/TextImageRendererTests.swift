import Testing
import CoreGraphics
@testable import CaptureStudio

@Suite struct TextImageRendererTests {
    private let canvas = CGSize(width: 1000, height: 1000)
    private let sentence = "the quick brown fox jumps over the lazy dog again"

    private func block(boxWidth: Double, autoWrap: Bool) -> TextBlock {
        var b = TextBlock(begin: 0, end: 1, text: sentence)
        b.fontSize = 0.05
        b.boxWidth = boxWidth
        b.autoWrap = autoWrap
        return b
    }

    @Test func narrowerBoxWrapsTaller() {
        let wide = TextImageRenderer.size(block(boxWidth: 0.9, autoWrap: true), canvas: canvas)
        let narrow = TextImageRenderer.size(block(boxWidth: 0.3, autoWrap: true), canvas: canvas)
        #expect(narrow.height > wide.height)
        #expect(narrow.width < wide.width)
    }

    @Test func autoWrapOffStaysSingleLine() {
        let wrapped = TextImageRenderer.size(block(boxWidth: 0.3, autoWrap: true), canvas: canvas)
        let noWrap = TextImageRenderer.size(block(boxWidth: 0.3, autoWrap: false), canvas: canvas)
        #expect(noWrap.height < wrapped.height)   // single line is shorter
        #expect(noWrap.width > wrapped.width)      // and extends wider
    }
}
