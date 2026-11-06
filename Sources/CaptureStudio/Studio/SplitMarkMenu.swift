import Foundation

/// One entry in a split mark's popover menu.
struct SplitMarkItem: Equatable, Identifiable {
    var id: String { title }
    let title: String
    let action: CutAction
    let enabled: Bool
    /// Why the item is disabled (nil when enabled).
    let help: String?
}

/// Pure menu model for the split mark between two adjacent segments. No SwiftUI.
enum SplitMarkMenu {
    /// Items for the mark at the start of segment `rightID`; nil when `rightID` is not a boundary.
    static func items(segments: [TimelineSegment], rightID: UUID) -> [SplitMarkItem]? {
        let s = segments.sorted { $0.start < $1.start }
        guard let i = s.firstIndex(where: { $0.id == rightID }), i > 0 else { return nil }
        let left = s[i - 1], right = s[i]
        switch (left.hidden, right.hidden) {
        case (false, false):
            return [SplitMarkItem(title: "Remove split", action: .removeSplit(rightID: right.id),
                                  enabled: true, help: nil)]
        case (true, true):
            return nil   // adjacent hidden runs are coalesced; never a real boundary
        default:
            let canCut = TimelineSegments.visibleCount(s) > 1
            return [item(for: left, side: "before", canCut: canCut),
                    item(for: right, side: "after", canCut: canCut)]
        }
    }

    private static func item(for seg: TimelineSegment, side: String, canCut: Bool) -> SplitMarkItem {
        let range = "\(TimelineScale.timecode(seg.start))\u{2013}\(TimelineScale.timecode(seg.end))"
        if seg.hidden {
            return SplitMarkItem(title: "Restore the part \(side) (\(range))",
                                 action: .restoreSegmentID(seg.id), enabled: true, help: nil)
        }
        return SplitMarkItem(title: "Cut the part \(side) (\(range))", action: .hideSegmentID(seg.id),
                             enabled: canCut, help: canCut ? nil : "Can't cut the last visible part")
    }
}
