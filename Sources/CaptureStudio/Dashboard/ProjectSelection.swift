/// Dashboard card selection: click / Cmd-click / Shift-click range, over the
/// cards' *display order* (which differs from `DashboardModel.visible` when
/// date groups reorder an Oldest sort). Pure value type; ids are
/// `ProjectSummary.id`.
///
/// Intended semantics (Finder-like): Shift-extend replaces the selection with
/// the anchor→target range; after a Cmd-deselect the anchor stays on that
/// now-unselected card.
struct ProjectSelection: Equatable {
    private(set) var ids: Set<String> = []
    /// Last plain/Cmd click target; the fixed end of a Shift range.
    private(set) var anchor: String?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The single selected id, or nil when 0 or ≥2 are selected.
    var single: String? { ids.count == 1 ? ids.first : nil }

    mutating func click(_ id: String) {
        ids = [id]
        anchor = id
    }

    mutating func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        anchor = id
    }

    /// Tick circle on a card (mouse-only multi-select).
    enum Checkbox: Equatable { case hidden, empty, checked }

    /// Nothing selected → no circles. One selected → it's a plain single
    /// selection (no tick); other cards offer an empty circle on hover.
    /// Two or more → selected cards show a tick, others a circle on hover.
    func checkbox(for id: String, hovering: Bool) -> Checkbox {
        if ids.isEmpty { return .hidden }
        if ids.contains(id) { return ids.count >= 2 ? .checked : .hidden }
        return hovering ? .empty : .hidden
    }

    mutating func extend(to id: String, order: [String]) {
        guard let target = order.firstIndex(of: id) else { return }
        guard let anchor, let start = order.firstIndex(of: anchor) else {
            click(id)
            return
        }
        ids = Set(order[min(start, target)...max(start, target)])
    }

    mutating func selectAll(_ order: [String]) {
        ids = Set(order)
        if let anchor, ids.contains(anchor) { return }
        anchor = order.first
    }

    mutating func clear() {
        ids = []
        anchor = nil
    }

    mutating func prune(keeping order: [String]) {
        let keep = Set(order)
        ids.formIntersection(keep)
        if let anchor, !keep.contains(anchor) { self.anchor = nil }
    }
}
