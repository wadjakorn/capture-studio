import Testing
import Foundation
@testable import CaptureStudio

struct SplitMarkMenuTests {
    @Test func bothVisibleOffersRemoveOnly() {
        let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
        let items = SplitMarkMenu.items(segments: s, rightID: s[1].id)!
        #expect(items.map(\.title) == ["Remove split"])
        #expect(items[0].action == .removeSplit(rightID: s[1].id)); #expect(items[0].enabled)
    }
    @Test func leftVisibleRightHiddenOffersCutBeforeThenRestoreAfter() {
        var s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 2).segments
        s = TimelineSegments.cut(s, range: 4..<7)                        // [0,2) [2,4) [4,7)h [7,10)
        let items = SplitMarkMenu.items(segments: s, rightID: s[2].id)!
        #expect(items.map(\.title) == ["Cut the part before (00:02.0–00:04.0)", "Restore the part after (00:04.0–00:07.0)"])
        #expect(items[0].action == .hideSegmentID(s[1].id)); #expect(items[1].action == .restoreSegmentID(s[2].id))
        #expect(items.allSatisfy { $0.enabled })
    }
    @Test func leftHiddenRightVisibleOffersRestoreBeforeThenCutAfter() {
        let s = TimelineSegments.cut(TimelineSegments.split(TimelineSegments.full(duration: 10), at: 7).segments, range: 0..<4)
        let items = SplitMarkMenu.items(segments: s, rightID: s[1].id)!   // [0,4)h | [4,7) [7,10)
        #expect(items.map(\.title) == ["Restore the part before (00:00.0–00:04.0)", "Cut the part after (00:04.0–00:07.0)"])
    }
    @Test func menuDisablesCutOfLastVisible() {
        let s = TimelineSegments.cut(TimelineSegments.full(duration: 10), range: 0..<4)
        let items = SplitMarkMenu.items(segments: s, rightID: s[1].id)!
        #expect(items[1].title.hasPrefix("Cut")); #expect(!items[1].enabled)
        #expect(items[1].help == "Can't cut the last visible part")
    }
    @Test func firstSegmentAndUnknownIdAreNotBoundaries() {
        let s = TimelineSegments.split(TimelineSegments.full(duration: 10), at: 4).segments
        #expect(SplitMarkMenu.items(segments: s, rightID: s[0].id) == nil)
        #expect(SplitMarkMenu.items(segments: s, rightID: UUID()) == nil)
    }
}
