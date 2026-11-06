import AppKit
import SwiftUI

struct DashboardView: View {
    @StateObject private var model = DashboardModel()
    @State private var renaming: ProjectSummary?
    @State private var renameText = ""
    @State private var renameError: String?
    /// Other project names beside the one being renamed, snapshotted when the
    /// sheet opens so live validation doesn't hit the disk per keystroke.
    @State private var renameSiblings: Set<String> = []
    /// A menu action refused because the project is in use: why, and what to do.
    @State private var blocked: (title: String, message: String)?
    /// Projects awaiting trash confirmation (the unlocked part of the request).
    @State private var trashing: [ProjectSummary]?
    /// How many requested projects were locked and will be skipped.
    @State private var trashSkipped = 0
    /// Snapshot so the title doesn't blank while the dialog fades out
    /// (`trashing` is nil'd on dismiss).
    @State private var trashTitle = ""
    @State private var errorMessage: String?
    /// Click / ⌘-click / ⇧-click selection. Esc / empty-space click clears;
    /// Return opens a single selection; ⌘⌫ trashes it.
    @State private var selection = ProjectSelection()
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 380)
        // Here, not inside `content`: its grid branch is gone while "No
        // matches" shows, and the selection must still drop hidden cards.
        .onChange(of: model.visible.map(\.id)) { _, ids in selection.prune(keeping: ids) }
        .onAppear { model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .projectLibraryDidChange)) { _ in
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Only this window's key events (sheets/panels also post it).
            if (note.object as? NSWindow)?.identifier == DashboardLauncher.windowID {
                model.reload()
            }
        }
        .sheet(item: $renaming) { project in renameSheet(project) }
        .confirmationDialog(
            trashTitle,
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
            presenting: trashing
        ) { projects in
            Button("Move to Trash", role: .destructive) { commitTrash(projects) }
            Button("Cancel", role: .cancel) {}
        } message: { projects in
            Text(Self.trashMessage(count: projects.count, skipped: trashSkipped))
        }
        .alert(blocked?.title ?? "",
               isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
            Button("OK") {}
        } message: {
            Text(blocked?.message ?? "")
        }
        .alert("Couldn't complete that",
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            OpenRecorderButton()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
            .frame(maxWidth: 260)

            Picker("Sort", selection: $model.sort) {
                Text("Newest").tag(ProjectSort.newest)
                Text("Oldest").tag(ProjectSort.oldest)
                Text("Name").tag(ProjectSort.name)
                Text("Size").tag(ProjectSort.size)
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            if selection.count > 1 {
                Text("\(selectedProjects.count) selected")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button { requestTrash(selectedProjects) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Move the selected projects to the Trash (⌘⌫)")
            .disabled(selectedProjects.isEmpty || searchFocused)

            Button("Open…") { StudioLauncher.promptAndOpen() }
            Button("Show Folder") {
                NSWorkspace.shared.open(ProjectBundle.defaultRecordingsDirectory())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let items = model.visible
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "film.stack").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "No recordings yet" : "No matches")
                    .font(.title3).foregroundStyle(.secondary)
                if model.query.isEmpty {
                    OpenRecorderButton()
                        .controlSize(.large)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let groups = (model.sort == .newest || model.sort == .oldest)
                ? ProjectLibrary.grouped(items, now: Date()) : nil
            // Shift-click ranges follow what's on screen: date groups reorder
            // an Oldest sort, so `items` order isn't the display order.
            let displayOrder = groups?.flatMap { $0.items.map(\.id) } ?? items.map(\.id)
            GeometryReader { proxy in
                ScrollView {
                    Group {
                        if let groups {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(groups, id: \.title) { group in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(group.title.uppercased())
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        grid(group.items, order: displayOrder)
                                    }
                                }
                            }
                        } else {
                            grid(items, order: displayOrder)
                        }
                    }
                    .padding(16)
                    // Fill the viewport so a click on empty space below short
                    // content still lands here and clears the selection.
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        searchFocused = false
                        selection.clear()
                    }
                }
            }
            .background { selectionKeys(items, order: displayOrder) }
        }
    }

    /// Return opens a single selection / Esc clears / ⌘A selects all. Hidden
    /// key-equivalent buttons work wherever focus is, unlike onKeyPress; they
    /// stand down while the search field is typing (its own ⌘A / Return win).
    @ViewBuilder
    private func selectionKeys(_ items: [ProjectSummary], order: [String]) -> some View {
        if !searchFocused {
            let single = selection.single.flatMap { id in items.first { $0.id == id } }
            Group {
                Button("") { selection.selectAll(order) }
                    .keyboardShortcut("a", modifiers: .command)
                if !selection.isEmpty {
                    Button("") { if let single { model.open(single) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(single?.status != .ready)
                    Button("") { selection.clear() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func grid(_ items: [ProjectSummary], order: [String]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items) { project in
                ProjectCell(project: project,
                            busy: model.busy.contains(project.id),
                            selected: selection.contains(project.id),
                            checkbox: { selection.checkbox(for: project.id, hovering: $0) },
                            onClick: { cardClicked(project, order: order) },
                            onCheck: {
                                searchFocused = false
                                selection.toggle(project.id)
                            })
                    .contextMenu { menu(for: project) }
            }
        }
    }

    private func cardClicked(_ project: ProjectSummary, order: [String]) {
        // A Button click doesn't take first responder from the search field;
        // without this the selection keys stay dead and ⌘⌫ would erase the
        // query instead.
        searchFocused = false
        // Fires per click; the second click of a double-click carries
        // clickCount 2. Selecting immediately (no wait for a possible
        // double-click) keeps the click snappy.
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        let isDouble = (event?.clickCount ?? 1) >= 2
        if flags.contains(.command) {
            if !isDouble { selection.toggle(project.id) }
        } else if flags.contains(.shift) {
            selection.extend(to: project.id, order: order)
        } else if isDouble {
            selection.click(project.id)
            model.open(project)
        } else {
            selection.click(project.id)
        }
    }

    @ViewBuilder
    private func menu(for project: ProjectSummary) -> some View {
        Button("Open") { model.open(project) }
            .disabled(project.status != .ready)
        // Rename / Duplicate / Trash stay enabled while the project is merely
        // in use and explain why on click — a disabled menu item can't say
        // why (menus don't show .help tooltips).
        Button("Rename…") {
            attempt(.rename, on: project) {
                renameText = project.name
                renameError = nil
                renameSiblings = model.renameSiblings(for: project)
                renaming = project
            }
        }
        // Duplicate can never work on these: say so in the item itself.
        switch project.status {
        case .incomplete:
            Button("Duplicate (incomplete recording)") {}.disabled(true)
        case .unreadable:
            Button("Duplicate (needs newer version)") {}.disabled(true)
        case .ready, .recording:
            Button("Duplicate") {
                attempt(.duplicate, on: project) {
                    performAsync { try await model.duplicate(project) }
                }
            }
        }
        Button("Show in Finder") { model.revealInFinder(project) }
        Divider()
        if project.isExternal {
            Button("Remove from Library") { model.removeFromLibrary(project) }
        }
        if selection.count > 1 && selection.contains(project.id) {
            let batch = selectedProjects
            Button("Move \(batch.count) Projects to Trash", role: .destructive) {
                requestTrash(batch)
            }
        } else {
            Button("Move to Trash", role: .destructive) { requestTrash([project]) }
        }
    }

    // MARK: - Trash

    /// Selected projects that are on screen, in display-independent model order.
    private var selectedProjects: [ProjectSummary] {
        model.visible.filter { selection.contains($0.id) }
    }

    /// One funnel for the menu, toolbar and ⌘⌫. Locked projects are skipped;
    /// if nothing is left, explain why instead of confirming.
    private func requestTrash(_ projects: [ProjectSummary]) {
        guard !projects.isEmpty else { return }
        let (allowed, locked) = model.trashPartition(projects)
        if allowed.isEmpty {
            if projects.count == 1, let project = projects.first {
                attempt(.trash, on: project) {}
            } else {
                blocked = (title: "Can't Move to Trash",
                           message: "All \(projects.count) selected projects are in use (recording, "
                               + "open in Studio, or being duplicated). Try again when they're free.")
            }
            return
        }
        trashSkipped = locked.count
        trashTitle = allowed.count == 1
            ? "Move “\(allowed[0].name)” to the Trash?"
            : "Move \(allowed.count) Projects to the Trash?"
        trashing = allowed
    }

    nonisolated static func trashMessage(count: Int, skipped: Int) -> String {
        let pronoun = count == 1 ? "it" : "them"
        if skipped > 0 { return "\(skipped) in use will be skipped. You can restore \(pronoun) from the Trash." }
        return "You can restore \(pronoun) from the Trash."
    }

    private func commitTrash(_ projects: [ProjectSummary]) {
        let result = model.moveToTrash(projects)
        // Drop trashed cards now; the async reload lands a moment later.
        let gone = Set(result.trashed.map(\.id))
        selection.prune(keeping: model.visible.map(\.id).filter { !gone.contains($0) })
        let lines = result.failed.map { "“\($0.project.name)”: \($0.message)" }
            + result.skipped.map { "“\($0.name)” is in use and was skipped." }
        guard !lines.isEmpty else { return }
        // Next turn: presenting an alert in the same update that dismisses
        // the confirmation dialog can be dropped.
        let message = lines.joined(separator: "\n")
        DispatchQueue.main.async { errorMessage = message }
    }

    /// Runs `action` unless the project is locked right now (checked at click
    /// time, not when the menu was built); then explains why instead.
    private func attempt(_ action: ProjectAction, on project: ProjectSummary, _ run: () -> Void) {
        if let reason = model.lockReason(project, for: action) {
            blocked = (title: "Can't \(action.title)",
                       message: reason.message(projectName: project.name, action: action))
        } else {
            run()
        }
    }

    // MARK: - Rename

    private func renameSheet(_ project: ProjectSummary) -> some View {
        let issue = DashboardModel.renameIssue(renameText, currentName: project.name,
                                               siblings: renameSiblings)
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canCommit = issue == nil && renameError == nil
            && !trimmed.isEmpty && trimmed != project.name
        return VStack(alignment: .leading, spacing: 12) {
            Text("Rename Project").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { if canCommit { commitRename(project) } }
                .onChange(of: renameText) { _, _ in renameError = nil }
            if let message = renameError ?? issue {
                Text(message).font(.caption).foregroundStyle(.red)
                    .frame(width: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commitRename(project) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
    }

    private func commitRename(_ project: ProjectSummary) {
        do {
            try model.rename(project, to: renameText)
            renaming = nil
        } catch {
            renameError = error.localizedDescription
        }
    }

    private func perform(_ work: () throws -> Void) {
        do { try work() } catch { errorMessage = error.localizedDescription }
    }

    private func performAsync(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct ProjectCard: View {
    let project: ProjectSummary
    let busy: Bool
    let selected: Bool
    let hovering: Bool

    @State private var thumbnail: CGImage?
    @State private var duration: TimeInterval?

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Fixed 16:9 slot that never sizes from the image: every card has
            // identical geometry whatever the recording's aspect ratio.
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { thumbnailContent }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    if project.status == .ready, let duration {
                        Text(Self.format(duration))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }

            HStack(spacing: 4) {
                Text(project.name).font(.callout.weight(.medium)).lineLimit(1)
                if project.hasCamera {
                    Image(systemName: "camera.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Includes camera")
                }
                if project.isCameraMain {
                    Image(systemName: "video.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Camera recording")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let date = project.recordedAt {
                    Text(Self.dateFormatter.localizedString(for: date, relativeTo: Date()))
                    Text("·")
                }
                Text(Self.sizeFormatter.string(fromByteCount: project.byteSize))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.primary.opacity(hovering || selected ? 0.06 : 0))
                .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: 4, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.12 : 0),
                              lineWidth: selected ? 2.5 : 1)
        }
        // Whole card (thumbnail, text, padding) is the click / hover target.
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: selected)
        // Lazy per cell: only visible cells run this. Ready projects only —
        // others have no media to read.
        // Keyed on status too: a card that flips to .ready on reload (recording
        // finished) must load its media; leaving .ready drops stale values.
        .task(id: "\(project.id)|\(String(describing: project.status))") {
            guard project.status == .ready else {
                thumbnail = nil
                duration = nil
                return
            }
            thumbnail = await ThumbnailStore.shared.image(bundleURL: project.url)
            duration = await ThumbnailStore.shared.duration(bundleURL: project.url)
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        ZStack {
            if let thumbnail, project.status == .ready {
                // Letterboxed on neutral dark so portrait / area captures
                // show the whole frame.
                Color(white: 0.11)
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.primary.opacity(0.08)
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
            }
            statusOverlay
            if busy {
                Color.black.opacity(0.35)
                ProgressView().controlSize(.small)
            }
        }
    }

    private var placeholderSymbol: String {
        switch project.status {
        case .ready: return "film"
        case .recording: return "record.circle"
        case .incomplete, .unreadable: return "exclamationmark.triangle"
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch project.status {
        case .ready:
            EmptyView()
        case .recording:
            badge("Recording…", symbol: "circle.fill", tint: .red)
        case .incomplete:
            badge("Incomplete", symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .unreadable:
            badge("Needs newer version", symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func badge(_ text: String, symbol: String, tint: Color) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.regularMaterial))
            .padding(.bottom, 8)
        }
    }

    private static func format(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One grid cell: the card button plus a tick circle over the thumbnail's
/// top-left corner — mouse-only multi-select (rules: `ProjectSelection.checkbox`).
/// The circle is a sibling overlay, not inside the card's label, so its click
/// never reaches the card. A plain card click still single-selects.
private struct ProjectCell: View {
    let project: ProjectSummary
    let busy: Bool
    let selected: Bool
    let checkbox: (_ hovering: Bool) -> ProjectSelection.Checkbox
    let onClick: () -> Void
    let onCheck: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onClick) {
            ProjectCard(project: project, busy: busy, selected: selected, hovering: hovering)
        }
        .buttonStyle(ProjectCardButtonStyle())
        .overlay(alignment: .topLeading) {
            let state = checkbox(hovering)
            if state != .hidden {
                let checked = state == .checked
                Button(action: onCheck) {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(checked ? .palette : .monochrome)
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .background(Circle().fill(.black.opacity(checked ? 0 : 0.25)).padding(2))
                        .padding(6)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(checked ? "Deselect" : "Add to selection")
                .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Card press feedback: a brief shrink while the mouse is down. Plain
/// otherwise — the card draws its own hover/selection chrome.
private struct ProjectCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Primary call to action: close the Dashboard and open the recorder popup.
private struct OpenRecorderButton: View {
    var body: some View {
        Button {
            DashboardLauncher.openRecorder()
        } label: {
            Label {
                Text("Open Recorder").fontWeight(.semibold)
            } icon: {
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .white)
            }
        }
        .buttonStyle(.bordered)
        .help("Close this window and open the recorder")
    }
}
