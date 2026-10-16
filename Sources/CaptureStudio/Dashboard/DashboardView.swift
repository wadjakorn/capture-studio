import AppKit
import SwiftUI

struct DashboardView: View {
    @StateObject private var model = DashboardModel()
    @State private var renaming: ProjectSummary?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var trashing: ProjectSummary?
    @State private var errorMessage: String?
    /// Single-click selection (one at a time). Esc / empty-space click clears;
    /// Return opens it.
    @State private var selectedID: String?
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 380)
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
            "Move “\(trashing?.name ?? "")” to the Trash?",
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
            presenting: trashing
        ) { project in
            Button("Move to Trash", role: .destructive) {
                perform { try model.moveToTrash(project) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can restore it from the Trash.")
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
            GeometryReader { proxy in
                ScrollView {
                    Group {
                        if model.sort == .newest || model.sort == .oldest {
                            let groups = ProjectLibrary.grouped(items, now: Date())
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(groups, id: \.title) { group in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(group.title.uppercased())
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        grid(group.items)
                                    }
                                }
                            }
                        } else {
                            grid(items)
                        }
                    }
                    .padding(16)
                    // Fill the viewport so a click on empty space below short
                    // content still lands here and clears the selection.
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedID = nil }
                }
            }
            .background { selectionKeys(items) }
        }
    }

    /// Return opens / Esc clears the selected card. Hidden key-equivalent
    /// buttons work wherever focus is, unlike onKeyPress; they exist only while
    /// a card is selected and stand down while the search field is typing.
    @ViewBuilder
    private func selectionKeys(_ items: [ProjectSummary]) -> some View {
        if let selectedID, !searchFocused {
            let selected = items.first { $0.id == selectedID }
            Group {
                Button("") { if let selected { model.open(selected) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected?.status != .ready)
                Button("") { self.selectedID = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func grid(_ items: [ProjectSummary]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items) { project in
                Button {
                    // Fires per click; the second click of a double-click
                    // carries clickCount 2. Selecting immediately (no wait
                    // for a possible double-click) keeps the click snappy.
                    selectedID = project.id
                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.open(project) }
                } label: {
                    ProjectCard(project: project,
                                busy: model.busy.contains(project.id),
                                selected: selectedID == project.id)
                }
                .buttonStyle(ProjectCardButtonStyle())
                .contextMenu { menu(for: project) }
            }
        }
    }

    @ViewBuilder
    private func menu(for project: ProjectSummary) -> some View {
        let locked = model.isLocked(project)
        let lockReason = model.busy.contains(project.id) ? "Duplicating"
            : project.status == .recording ? "Recording" : "Open in Studio"
        Button("Open") { model.open(project) }
            .disabled(project.status != .ready)
        Button("Rename…") {
            renameText = project.name
            renameError = nil
            renaming = project
        }
        .disabled(locked)
        .help(locked ? lockReason : "")
        Button("Duplicate") { performAsync { try await model.duplicate(project) } }
            .disabled(project.status != .ready || model.busy.contains(project.id)
                       || model.isRecordingLive(project))
        Button("Show in Finder") { model.revealInFinder(project) }
        Divider()
        if project.isExternal {
            Button("Remove from Library") { model.removeFromLibrary(project) }
        }
        Button("Move to Trash", role: .destructive) { trashing = project }
            .disabled(locked)
            .help(locked ? lockReason : "")
    }

    // MARK: - Rename

    private func renameSheet(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Project").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitRename(project) }
                .onChange(of: renameText) { _, _ in renameError = nil }
            if let renameError {
                Text(renameError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commitRename(project) }
                    .keyboardShortcut(.defaultAction)
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

    @State private var hovering = false
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
        .onHover { hovering = $0 }
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
