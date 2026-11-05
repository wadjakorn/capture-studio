import Testing
@testable import CaptureStudio

@Suite struct EditHistoryTests {
    @Test func recordThenUndoReturnsPrevious() {
        var h = EditHistory(initial: 0)
        h.record(1)
        #expect(h.undo() == 0)
        #expect(h.current == 0)
        #expect(h.canRedo)
    }

    @Test func redoReappliesUndone() {
        var h = EditHistory(initial: 0)
        h.record(1)
        _ = h.undo()
        #expect(h.redo() == 1)
        #expect(h.current == 1)
        #expect(!h.canRedo)
    }

    @Test func identicalStateIsNotRecorded() {
        var h = EditHistory(initial: 0)
        h.record(1)
        h.record(1)
        #expect(h.canUndo)
        #expect(h.undo() == 0)
        #expect(h.undo() == nil)
    }

    @Test func newRecordClearsRedo() {
        var h = EditHistory(initial: 0)
        h.record(1)
        _ = h.undo()
        h.record(2)
        #expect(!h.canRedo)
    }

    @Test func capDropsOldest() {
        var h = EditHistory(initial: 0, cap: 3)
        for i in 1...4 { h.record(i) }
        #expect(h.undo() == 3)
        #expect(h.undo() == 2)
        #expect(h.undo() == 1)
        #expect(h.undo() == nil)
    }

    @Test func undoOnEmptyIsNil() {
        var h = EditHistory(initial: 0)
        #expect(h.undo() == nil)
        #expect(h.redo() == nil)
        #expect(!h.canUndo)
        #expect(!h.canRedo)
    }

    @Test func replaceCurrentKeepsStacks() {
        var h = EditHistory(initial: 0)
        h.record(1)
        h.replaceCurrent(5)
        #expect(h.undo() == 0)
        #expect(h.redo() == 5)
    }

    @Test func resetClearsStacks() {
        var h = EditHistory(initial: 0)
        h.record(1)
        _ = h.undo()
        h.reset(to: 9)
        #expect(h.current == 9)
        #expect(!h.canUndo)
        #expect(!h.canRedo)
    }
}
