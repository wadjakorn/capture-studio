import Testing
@testable import CaptureStudio

@Suite struct ProjectSelectionTests {
    private let o = ["a", "b", "c", "d", "e"]

    @Test func clickSelectsOnlyThat() {
        var s = ProjectSelection()
        s.click("b")
        s.click("d")
        #expect(s.ids == ["d"])
        #expect(s.anchor == "d")
        #expect(s.single == "d")
    }

    @Test func toggleAddsAndRemoves() {
        var s = ProjectSelection()
        s.click("a")
        s.toggle("c")
        #expect(s.ids == ["a", "c"])
        #expect(s.single == nil)
        #expect(s.count == 2)
        s.toggle("a")
        #expect(s.ids == ["c"])
        #expect(s.anchor == "a")
    }

    @Test func extendSelectsRangeFromAnchorEitherDirection() {
        var s = ProjectSelection()
        s.click("b")
        s.extend(to: "d", order: o)
        #expect(s.ids == ["b", "c", "d"])
        s.extend(to: "a", order: o)
        #expect(s.ids == ["a", "b"])
        #expect(s.anchor == "b")
    }

    @Test func extendWithoutAnchorActsLikeClick() {
        var s = ProjectSelection()
        s.extend(to: "c", order: o)
        #expect(s.ids == ["c"])
        #expect(s.anchor == "c")

        var fresh = ProjectSelection()
        fresh.extend(to: "zzz", order: o)
        #expect(fresh.isEmpty)
    }

    @Test func extendToUnknownIdIsNoOp() {
        var s = ProjectSelection()
        s.click("a")
        s.extend(to: "zzz", order: o)
        #expect(s.ids == ["a"])
        #expect(s.anchor == "a")
    }

    @Test func rangeUsesGivenDisplayOrder() {
        var s = ProjectSelection()
        s.click("a")
        s.extend(to: "b", order: ["c", "a", "e", "b"])
        #expect(s.ids == ["a", "e", "b"])
    }

    @Test func selectAllAndClear() {
        var s = ProjectSelection()
        s.selectAll(o)
        #expect(s.count == 5)
        s.clear()
        #expect(s.isEmpty)
        #expect(s.anchor == nil)
    }

    @Test func pruneDropsMissingIdsAndAnchor() {
        var s = ProjectSelection()
        s.click("b")
        s.toggle("d")
        s.prune(keeping: ["a", "d"])
        #expect(s.ids == ["d"])
        #expect(s.anchor == "d")
        s.prune(keeping: ["a"])
        #expect(s.isEmpty)
        #expect(s.anchor == nil)
    }

    @Test func noCheckboxWhenNothingSelected() {
        let s = ProjectSelection()
        #expect(s.checkbox(for: "a", hovering: true) == .hidden)
        #expect(s.checkbox(for: "a", hovering: false) == .hidden)
    }

    @Test func singleSelectionOffersCirclesOnOtherCardsOnHover() {
        var s = ProjectSelection()
        s.click("a")
        // The selected card itself is a plain single selection: no tick.
        #expect(s.checkbox(for: "a", hovering: true) == .hidden)
        #expect(s.checkbox(for: "b", hovering: true) == .empty)
        #expect(s.checkbox(for: "b", hovering: false) == .hidden)
    }

    @Test func multiSelectionShowsTicksAlwaysAndCirclesOnHover() {
        var s = ProjectSelection()
        s.click("a")
        s.toggle("b")
        #expect(s.checkbox(for: "a", hovering: false) == .checked)
        #expect(s.checkbox(for: "b", hovering: true) == .checked)
        #expect(s.checkbox(for: "c", hovering: true) == .empty)
        #expect(s.checkbox(for: "c", hovering: false) == .hidden)
    }

    @Test func untickingBackToOneReturnsToSingleSelection() {
        var s = ProjectSelection()
        s.click("a")
        s.toggle("b")
        s.toggle("b")
        #expect(s.single == "a")
        #expect(s.checkbox(for: "a", hovering: true) == .hidden)
    }

    @Test func plainClickDuringMultiSelectionCollapsesToSingle() {
        var s = ProjectSelection()
        s.click("a")
        s.toggle("b")
        s.click("c")
        #expect(s.ids == ["c"])
        #expect(s.checkbox(for: "c", hovering: true) == .hidden)
    }
}
