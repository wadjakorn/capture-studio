/// Snapshot undo/redo stack. `record(_:)` is the single entry point: pass the state
/// after every committed change; the previous state becomes the undo step.
/// Identical consecutive states are not recorded (coalescing), and the undo stack
/// is bounded by `cap` (oldest entries dropped first). Pure value type — no UI, no
/// model dependency — so it is unit-tested directly.
struct EditHistory<State: Equatable> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private let cap: Int

    /// The state the editor is currently in.
    private(set) var current: State

    init(initial: State, cap: Int = 100) {
        self.current = initial
        self.cap = max(1, cap)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Commit `state` as the new current. No-op when equal to `current`; otherwise
    /// the old `current` becomes an undo step and the redo stack is cleared.
    mutating func record(_ state: State) {
        guard state != current else { return }
        undoStack.append(current)
        if undoStack.count > cap { undoStack.removeFirst(undoStack.count - cap) }
        redoStack.removeAll()
        current = state
    }

    /// Step back: current moves to the redo stack. Returns the new `current`, or
    /// nil when there is nothing to undo.
    mutating func undo() -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        current = previous
        return current
    }

    /// Step forward again after an undo. Returns the new `current`, or nil when
    /// there is nothing to redo.
    mutating func redo() -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        current = next
        return current
    }

    /// Set `current` and clear both stacks (used on load).
    mutating func reset(to state: State) {
        current = state
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Overwrite `current` without touching either stack.
    mutating func replaceCurrent(_ state: State) {
        current = state
    }
}
