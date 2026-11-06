# Dashboard Multi-Select Trash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user select several projects in the Dashboard and move them all to the Trash in one confirmed action.

**Architecture:** A pure `ProjectSelection` value type owns selection rules (click / Cmd-click / Shift-range / select-all / prune) over the *display order* of cards. `DashboardModel` gains a batch trash that partitions projects by `lockReason(_, for: .trash)`, trashes the unlocked ones, and returns a result value instead of throwing on the first problem. `DashboardView` swaps `selectedID: String?` for `ProjectSelection` and adds the Cmd-A / Cmd-Delete keys, a toolbar Trash button and a batch-aware context-menu item, all funnelling into one confirmation dialog.

**Tech Stack:** Swift 6, SwiftUI (macOS 15+), swift-testing 0.12.0.

**Spec:** Board ticket CS-0006 `yhxSBBaD_4IK` ("[feature] dashboard: multi-select projects for deletion") — its description is the spec.

## Global Constraints

- Must build and test under both Xcode and CLT: `swift test` and `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test`. No `#Preview`, no dependency bumps.
- Pure helpers get unit tests; SwiftUI glue is not unit-tested (project convention).
- Locked = `DashboardModel.lockReason(project, for: .trash) != nil` (duplicating / recording / open in Studio). Locked projects are skipped, never trashed.
- Single-project actions (Open, Rename, Duplicate, Show in Finder, Remove from Library) keep acting on the right-clicked card only.
- Return opens only when exactly one card is selected; double-click still opens the clicked card.
- Copy (exact):
  - Dialog title: one item → `Move “<name>” to the Trash?`; N items → `Move <N> Projects to the Trash?`
  - Dialog message when some are skipped: `<K> in use will be skipped. You can restore <it|them> from the Trash.` (`it` when exactly one will be trashed, else `them`); with nothing skipped: `You can restore it from the Trash.` (one) / `You can restore them from the Trash.` (many).
  - All selected locked (≥2): alert `Can't Move to Trash` / `All <N> selected projects are in use (recording, open in Studio, or being duplicated). Try again when they're free.`
  - Context-menu item on a card inside a multi-selection: `Move <N> Projects to Trash`; otherwise the existing `Move to Trash`.
  - Toolbar button: `Move to Trash` with `trash` symbol, `.help("Move the selected projects to the Trash (⌘⌫)")`. Always present (no layout shift); disabled when nothing visible is selected.
  - Alert after a batch with problems: existing "Couldn't complete that" alert, one line per item: failures `“<name>”: <localizedDescription>`, late-locked skips `“<name>” is in use and was skipped.`
- Intended selection semantics (documented, not bugs): Shift-extend *replaces* the selection with the anchor→target range (Cmd-picked cards outside it are dropped, as in Finder list view); after a Cmd-deselect the anchor is that now-unselected card.
- Tests must never touch the user's real Trash: test models inject `trashItem` = `removeItem`.

## Review Focus

1. **Shift-click range under Oldest sort with date groups** — cards are displayed Today → This Week → Earlier, but `model.visible` is oldest-first, so a range over `visible` selects the wrong cards. Range must use the *display order* (flattened groups when grouped). Pinned by `rangeUsesGivenDisplayOrder` (Task 1) and Task 3 step building `displayOrder`.
2. **Selection referencing projects that vanished** (filtered out by search, trashed, renamed → new id) — Cmd-Delete must not act on invisible projects. Pinned by `pruneDropsMissingIdsAndAnchor` (Task 1) and Task 3 pruning on `visible` change; batch trash resolves ids against `model.visible` at click time.
3. **Mixed batch where some projects are locked** — must trash the rest, not abort. Pinned by `batchTrashSkipsLockedAndTrashesRest` (Task 2).
4. **One item fails mid-batch** (e.g. already deleted on disk) — the others still go, failure reported. Pinned by `batchTrashContinuesPastFailure` (Task 2).
5. **Search field holds focus after typing** — clicking cards must hand focus back so Return/Esc/⌘A/⌘⌫ reach the grid (and ⌘⌫ doesn't erase the query). Pinned by Task 3 Step 3 (`searchFocused = false` on card/empty-space click) + manual check.
6. **Shift-click with no anchor** (nothing selected yet, or anchor pruned) — behaves like a plain click. Pinned by `extendWithoutAnchorActsLikeClick` (Task 1).

---

### Task 1: `ProjectSelection` pure selection model

**Files:**
- Create: `Sources/CaptureStudio/Dashboard/ProjectSelection.swift`
- Test: `Tests/CaptureStudioTests/ProjectSelectionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct ProjectSelection: Equatable {
      private(set) var ids: Set<String> = []
      private(set) var anchor: String?          // last plain/Cmd click target
      var isEmpty: Bool { get }
      var count: Int { get }
      func contains(_ id: String) -> Bool
      /// The single selected id, or nil when 0 or ≥2 are selected.
      var single: String? { get }
      mutating func click(_ id: String)                       // ids = [id], anchor = id
      mutating func toggle(_ id: String)                      // Cmd-click; anchor = id
      mutating func extend(to id: String, order: [String])    // Shift-click
      mutating func selectAll(_ order: [String])              // anchor unchanged if still present, else first
      mutating func clear()
      mutating func prune(keeping order: [String])            // drop ids/anchor not in order
  }
  ```

- [ ] **Step 1: Write failing tests** in `ProjectSelectionTests.swift` (`@Suite struct ProjectSelectionTests`), order `let o = ["a","b","c","d","e"]`:
  - `clickSelectsOnlyThat`: click "b" then click "d" → `ids == ["d"]`, `anchor == "d"`, `single == "d"`.
  - `toggleAddsAndRemoves`: click "a", toggle "c" → `ids == ["a","c"]`, `single == nil`; toggle "a" → `ids == ["c"]`, `anchor == "a"`.
  - `extendSelectsRangeFromAnchorEitherDirection`: click "b", extend to "d" → `["b","c","d"]`; extend to "a" (same anchor) → `["a","b"]` (range replaces previous range, anchor stays "b").
  - `extendWithoutAnchorActsLikeClick`: fresh selection, extend to "c" → `ids == ["c"]`, `anchor == "c"`; fresh selection, extend to "zzz" → still `isEmpty`.
  - `extendToUnknownIdIsNoOp`: click "a", extend to "zzz" with order `o` → selection unchanged (`ids == ["a"]`, `anchor == "a"`).
  - `rangeUsesGivenDisplayOrder`: order `["c","a","e","b"]`, click "a", extend to "b" → `ids == ["a","e","b"]`.
  - `selectAllAndClear`: selectAll(o) → `count == 5`; clear → `isEmpty`, `anchor == nil`.
  - `pruneDropsMissingIdsAndAnchor`: click "b", toggle "d", prune(keeping ["a","d"]) → `ids == ["d"]`, `anchor == "d"`; then prune(keeping ["a"]) → `isEmpty`, `anchor == nil`.

- [ ] **Step 2: Run** `swift test --filter ProjectSelectionTests` → FAIL (type missing).

- [ ] **Step 3: Implement `ProjectSelection`.** `extend`: first, if `id` not in `order` → no-op; then if `anchor` is nil or not in `order` → `click(id)`; else `ids = Set(order[min...max])`, anchor unchanged.

- [ ] **Step 4: Run** `swift test --filter ProjectSelectionTests` → PASS.

- [ ] **Step 5: Commit** (only with user confirmation — CLAUDE.md): `feat(dashboard): ProjectSelection value type for multi-select`.

### Task 2: Batch trash on `DashboardModel`

**Files:**
- Modify: `Sources/CaptureStudio/Dashboard/DashboardModel.swift` (next to `moveToTrash(_:)`)
- Test: `Tests/CaptureStudioTests/DashboardModelTests.swift`

**Interfaces:**
- Consumes: existing `lockReason(_:for:)`, `recents.remove(_:)`, `reload()`.
- Produces:
  ```swift
  struct TrashBatchResult: Equatable {
      var trashed: [ProjectSummary] = []
      var skipped: [ProjectSummary] = []                         // locked at call time
      var failed: [Failure] = []
      struct Failure: Equatable { var project: ProjectSummary; var message: String }
  }
  extension DashboardModel {
      /// Projects in `projects` that can be trashed now vs. those locked. Order preserved.
      func trashPartition(_ projects: [ProjectSummary]) -> (allowed: [ProjectSummary], locked: [ProjectSummary])
      /// Re-checks locks, trashes allowed ones one by one (continues past errors),
      /// removes each trashed URL from recents, reloads once at the end.
      @discardableResult
      func moveToTrash(_ projects: [ProjectSummary]) -> TrashBatchResult
  }
  ```
  Injection: add `trashItem: ((URL) throws -> Void)? = nil` init parameter resolved in the body (same pattern as `copyItem`) to `{ try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }`, used by both the single and batch trash. Single `moveToTrash(_ project:)` keeps its throwing contract.

- [ ] **Step 1: Write failing tests** (extend `makeModel` with an optional `trashItem:` parameter that defaults to the real one; real trashing of temp dirs is already what existing tests do):
  Test helper: `makeModel(..., trashItem:)` defaults to `{ try FileManager.default.removeItem(at: $0) }` — never the real Trash. Closures match projects by `$0.lastPathComponent` (not `URL ==`; `/var` vs `/private/var`).
  - `batchTrashSkipsLockedAndTrashesRest`: projects A, B, C; `isOpen` true only for `B.capturestudio`. `trashPartition([a,b,c])` → allowed names `["A","C"]`, locked `["B"]`. `moveToTrash([a,b,c])` → `trashed` names `["A","C"]`, `skipped` `["B"]`, `failed.isEmpty`; on disk A and C gone, B exists; after `reloadAndWait()` projects == `["B"]`.
  - `batchTrashContinuesPastFailure`: A, B, C; `trashItem` throws `CocoaError(.fileNoSuchFile)` for B, real trash otherwise → `trashed` `["A","C"]`, `failed.map(\.project.name) == ["B"]`, B still exists.
  - `batchTrashRemovesExternalFromRecents`: external project via `recents.noteOpened(outside)`; batch-trash it → `recents.externalProjects.isEmpty`.

- [ ] **Step 2: Run** `swift test --filter DashboardModelTests` → FAIL (missing API).

- [ ] **Step 3: Implement** as specified; `moveToTrash(_ project:)` routes through `trashItem`.

- [ ] **Step 4: Run** `swift test --filter DashboardModelTests` → PASS (existing tests included).

- [ ] **Step 5: Commit** (with confirmation): `feat(dashboard): batch move-to-trash that skips locked projects`.

### Task 3: Wire multi-select + batch trash into `DashboardView`

**Files:**
- Modify: `Sources/CaptureStudio/Dashboard/DashboardView.swift`

**Interfaces:**
- Consumes: `ProjectSelection` (Task 1), `trashPartition`, `moveToTrash(_ projects:)`, `TrashBatchResult` (Task 2).

- [ ] **Step 1: State.** Replace `@State selectedID: String?` with `@State private var selection = ProjectSelection()`; replace `@State trashing: ProjectSummary?` with `@State private var trashing: [ProjectSummary]?` (non-empty when the dialog is up; holds the *allowed* projects) and `@State private var trashSkipped = 0`.

- [ ] **Step 2: Display order.** Compute once in `content`: `let groups = (sort is newest/oldest) ? ProjectLibrary.grouped(items, now: Date()) : nil` and `let displayOrder = groups?.flatMap { $0.items.map(\.id) } ?? items.map(\.id)`. Render from `groups` (no second `grouped` call). Pass `displayOrder` to `grid` / the click handler.

- [ ] **Step 3: Click handling** in the card `Button` action, using `NSApp.currentEvent?.modifierFlags`:
  - clickCount ≥ 2 → `selection.click(id)` then `model.open(project)`.
  - `modifierFlags.contains(.command)` → `selection.toggle(id)`; else `.contains(.shift)` → `selection.extend(to: id, order: displayOrder)`; else `selection.click(id)`.
  - Every card click and the empty-space tap first set `searchFocused = false` (a Button click doesn't take first responder from the TextField; without this the keys stay dead and ⌘⌫ erases the query).
  - Card `selected:` = `selection.contains(project.id)`. Empty-space tap → `selection.clear()`.

- [ ] **Step 4: Pruning.** `.onChange(of: model.visible.map(\.id)) { _, ids in selection.prune(keeping: ids) }` on the outer `VStack` in `body` (not inside `content`'s if/else — the grid branch is absent while "No matches" shows).

- [ ] **Step 5: Keys** in `selectionKeys` (hidden buttons, same pattern; whole group still stands down while `searchFocused`):
  - Return → open only when `selection.single` resolves to a `.ready` project (disabled otherwise).
  - Esc → `selection.clear()` (only when non-empty).
  - Cmd-A (`.keyboardShortcut("a", modifiers: .command)`) → `selection.selectAll(displayOrder)`; present whenever items are non-empty (not only when something is selected). Must not fire while the search field has focus (text select-all wins).
  - ⌘⌫ lives on the toolbar button (Step 9), not here.

- [ ] **Step 6: `requestTrash(_ projects: [ProjectSummary])`** — single funnel for menu, toolbar, ⌘⌫:
  - `guard !projects.isEmpty else { return }`.
  - `let (allowed, locked) = model.trashPartition(projects)`.
  - `allowed.isEmpty` → if `projects.count == 1` use existing `attempt(.trash, …)` message; else the all-locked alert from Global Constraints.
  - else `trashing = allowed; trashSkipped = locked.count`.
  - `selectedProjects` = `model.visible.filter { selection.contains($0.id) }` resolved at call time.

- [ ] **Step 7: Confirmation dialog** — title/message per Global Constraints copy (count = `trashing.count`). Destructive button `Move to Trash` → `let r = model.moveToTrash(trashing)`; immediately `selection.prune(keeping:)` the visible ids minus `r.trashed` ids (don't wait for the async reload); if `r.failed` or `r.skipped` non-empty → `errorMessage` = joined lines per Global Constraints.

- [ ] **Step 8: Context menu.** `Move to Trash` item: if `selection.count > 1 && selection.contains(project.id)` → label `Move <N> Projects to Trash`, action `requestTrash(selectedProjects)`; else label `Move to Trash`, action `requestTrash([project])`. Other items unchanged.

- [ ] **Step 9: Toolbar.** Before `Open…`: `Button { requestTrash(selectedProjects) } label: { Label("Move to Trash", systemImage: "trash") }` with `.keyboardShortcut(.delete, modifiers: .command)`, the help text from Global Constraints, `.disabled(selectedProjects.isEmpty || searchFocused)`.

- [ ] **Step 10: Verify.** `swift build && swift test`, then `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test` → all green. `scripts/build-app.sh debug && pkill -x CaptureStudio; open dist/CaptureStudio.app` → app launches to Dashboard.

- [ ] **Step 11: Commit** (with confirmation): `feat(dashboard): multi-select projects and move them to the Trash together`.

## Manual checks (optional, user)

Cmd-click 3 cards → toolbar Trash → dialog "Move 3 Projects…" → gone. Shift-click across date groups in Oldest sort selects contiguous visible cards. Open one project in Studio, select it + 2 others, Cmd-Delete → dialog says "1 in use will be skipped". Type in search, Cmd-A selects text, not cards; then click a card and ⌘⌫ → trash dialog (query intact). Search unfocused, ⌘A selects all cards.

## Addendum: mouse-only multi-select (tick circles)

User follow-up: multi-select must work without the keyboard. Final rules (user-approved):

- Multi-select = `count >= 2`; no separate mode flag.
- `ProjectSelection.checkbox(for:hovering:) -> Checkbox (.hidden/.empty/.checked)`: nothing selected → hidden everywhere; one selected → that card hidden (plain single selection), other cards `.empty` on hover; ≥2 → selected cards `.checked` always, others `.empty` on hover. Tests: `noCheckboxWhenNothingSelected`, `singleSelectionOffersCirclesOnOtherCardsOnHover`, `multiSelectionShowsTicksAlwaysAndCirclesOnHover`, `untickingBackToOneReturnsToSingleSelection`, `plainClickDuringMultiSelectionCollapsesToSingle`.
- Circle click = `toggle`. Plain card click = `click` (single select) in every state; ⌘/⇧ clicks unchanged.
- `DashboardView.ProjectCell`: card button + sibling overlay circle at the thumbnail's top-left; hover state lives in the cell. Toolbar shows `N selected` when `count > 1`.
