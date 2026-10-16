import SwiftUI
import AVFoundation
import AppKit
import KeyboardShortcuts

struct RecorderMenuView: View {
    @EnvironmentObject private var session: RecordingSession

    @State private var displays: [DisplayItem] = []
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var cameras: [AVCaptureDevice] = []
    @State private var selectedCameraID: String?
    @State private var microphones: [AVCaptureDevice] = []
    @State private var selectedMicID: String?
    @State private var systemAudioEnabled = AppSettings.recordSystemAudio
    @State private var openStudioAfterRecording = AppSettings.openStudioAfterRecording
    @State private var captureAreaEnabled = AppSettings.captureAreaEnabled
    @State private var captureRegion: CGRect? = AppSettings.captureRegion
    @State private var captureRegionDisplayID: CGDirectDisplayID? = AppSettings.captureRegionDisplayID
    @State private var permissionGranted = Permissions.screenRecordingGranted()
    @State private var elapsed: TimeInterval = 0
    @State private var showDisplayMenu = false
    @State private var showCameraMenu = false
    @State private var showMicMenu = false
    @State private var showRecentMenu = false
    @ObservedObject private var recents = RecentProjectsStore.shared
    @State private var projectRows = ProjectMenuRows.empty

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: isRecording ? "record.circle.fill" : "circle.dotted")
                    .foregroundStyle(isRecording ? Color.red : Color.secondary)
                    .font(.system(size: 13))
                Text("Capture Studio")
                    .font(.subheadline.weight(.medium))
            }

            if !permissionGranted {
                permissionView
            } else {
                recorderView
            }

            if !session.warnings.isEmpty {
                ForEach(session.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            projectsSection

            Divider()

            HStack {
                Button {
                    openRecordingPanel()
                } label: {
                    Label("Open", systemImage: "folder.badge.plus")
                }
                Spacer()
                Button {
                    DashboardLauncher.show()
                } label: {
                    Label("Projects", systemImage: "square.grid.2x2")
                }
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 300)
        .task { await refreshDevices() }
        // Openability + meta reads touch the disk (possibly a network volume),
        // so they run off-main and only the result lands in @State.
        // The active recording is part of the key so its row reappears once the
        // session goes idle (activeBundleURL is state-derived → nil).
        .task(id: ProjectsKey(recent: recents.recent, last: recents.lastRecorded,
                              active: session.activeBundleURL)) {
            let recent = recents.recent, last = recents.lastRecorded
            let active = session.activeBundleURL
            let rows = await Task.detached(priority: .userInitiated) {
                ProjectMenuRows.load(recent: recent, last: last, activeRecording: active)
            }.value
            // A superseded task's detached load still finishes; don't let it
            // overwrite rows from the newer one.
            guard !Task.isCancelled else { return }
            projectRows = rows
        }
        .onChange(of: selectedDisplayID) { _, id in AppSettings.lastDisplayID = id }
        .onChange(of: selectedCameraID) { _, id in AppSettings.lastCameraID = id }
        .onChange(of: selectedMicID) { _, id in AppSettings.lastMicID = id }
        .onChange(of: systemAudioEnabled) { _, on in AppSettings.recordSystemAudio = on }
        .onChange(of: openStudioAfterRecording) { _, on in AppSettings.openStudioAfterRecording = on }
        .onChange(of: captureAreaEnabled) { _, on in AppSettings.captureAreaEnabled = on }
        .onChange(of: captureRegion) { _, r in AppSettings.captureRegion = r }
        .onChange(of: captureRegionDisplayID) { _, id in AppSettings.captureRegionDisplayID = id }
        .onReceive(tick) { _ in
            if case .recording(let startedAt) = session.state {
                elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private var permissionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Recording permission needed", systemImage: "exclamationmark.triangle")
                .font(.callout)
            Text("Grant access in System Settings, then relaunch the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Request") {
                    Permissions.requestScreenRecording()
                    permissionGranted = Permissions.screenRecordingGranted()
                }
                Button("Open Settings") { Permissions.openScreenRecordingSettings() }
            }
        }
    }

    @ViewBuilder
    private var recorderView: some View {
        switch session.state {
        case .recording:
            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text(formattedElapsed)
                        .font(.system(size: 34, weight: .medium).monospacedDigit())
                        .foregroundStyle(.red)
                    Text("Recording\(recordingTargetSuffix)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)

                Button {
                    Task { await session.stop() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .tint(.red)
                .keyboardShortcut(.escape, modifiers: [])

                Text("Press Esc to stop")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        case .arming:
            Label("Warming up…", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .armed:
            armedView
        case .preparing, .finishing:
            ProgressView()
                .controlSize(.small)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Dismiss") { session.resetFailure() }
            }
        case .idle:
            idleView
        }
    }

    private var armedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(armedHeader, systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(session.counting ? Color.secondary : Color.green)

            if let sz = session.armedAreaSize {
                Text("\(Int(sz.width)) × \(Int(sz.height))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    Task { await session.startCountdownThenBegin() }
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.counting || !session.canBeginArmed)

                Button("Cancel") {
                    Task { await session.cancelCountdownOrArming() }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    /// Armed-view header: interactive area nudges the user to adjust the box.
    private var armedHeader: String {
        if session.counting { return "Starting…" }
        // Area mode with nothing selected yet: Record is disabled until the user
        // picks an area (via the on-screen Select Area toggle).
        if captureAreaEnabled && !session.canBeginArmed { return "Select an area to record" }
        return captureAreaEnabled ? "Adjust area, then record" : "Sources ready"
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Source")

            captureModeRow

            // Area mode derives the display from where you drag; picker is for
            // whole-display capture only.
            if !captureAreaEnabled {
                dropdown("display", selection: displayLabel, isPresented: $showDisplayMenu) {
                    ForEach(displays) { display in
                        pickRow("\(display.name) (\(display.pixelWidth)×\(display.pixelHeight))",
                                selected: selectedDisplayID == display.id) {
                            selectedDisplayID = display.id
                            showDisplayMenu = false
                        }
                    }
                }
            }

            HStack {
                sectionHeader("Inputs")
                Spacer()
                Button {
                    Task { await refreshDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh devices")
            }
            .padding(.top, 6)

            dropdown("video", selection: deviceLabel(cameras, selectedCameraID),
                     isPresented: $showCameraMenu) {
                pickRow("None", selected: selectedCameraID == nil) {
                    selectedCameraID = nil
                    showCameraMenu = false
                }
                ForEach(cameras, id: \.uniqueID) { device in
                    pickRow(device.localizedName, selected: selectedCameraID == device.uniqueID) {
                        selectedCameraID = device.uniqueID
                        showCameraMenu = false
                    }
                }
            }

            dropdown("mic", selection: deviceLabel(microphones, selectedMicID),
                     isPresented: $showMicMenu) {
                pickRow("None", selected: selectedMicID == nil) {
                    selectedMicID = nil
                    showMicMenu = false
                }
                ForEach(microphones, id: \.uniqueID) { device in
                    pickRow(device.localizedName, selected: selectedMicID == device.uniqueID) {
                        selectedMicID = device.uniqueID
                        showMicMenu = false
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("System Audio")
                Spacer()
                Toggle("System Audio", isOn: $systemAudioEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            HStack(spacing: 6) {
                Image(systemName: "macwindow")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("Open Studio after recording")
                Spacer()
                Toggle("Open Studio after recording", isOn: $openStudioAfterRecording)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            Button {
                elapsed = 0
                // Read the persisted area FRESH from AppSettings — the session
                // writes it there directly after a drag, so the view's @State
                // copies can be stale within the same MenuBarExtra lifecycle.
                let savedRegion = AppSettings.captureRegion
                let savedDisplay = AppSettings.captureRegionDisplayID
                // Area mode seeds the saved region (editable live); full mode the picker's.
                let region = captureAreaEnabled ? savedRegion : nil
                // Seed display from the saved region; fall back to the picker so a
                // never-set area still has a screen to open the overlay on.
                let useDisplay = captureAreaEnabled
                    ? (savedDisplay ?? selectedDisplayID)
                    : selectedDisplayID
                // Full Display never selects an area. Area mode requires one only
                // when nothing is saved at all (a full-display area keeps its
                // display id, so it's recordable as-is).
                let areaSelection: AreaSelection = !captureAreaEnabled
                    ? .unavailable
                    : (savedRegion == nil && savedDisplay == nil ? .required : .optional)
                Task {
                    await session.toggle(displayID: useDisplay,
                                         cameraID: selectedCameraID,
                                         micID: selectedMicID,
                                         systemAudio: systemAudioEnabled,
                                         region: region,
                                         activateForPrompts: false,
                                         previewFirst: true,
                                         areaSelection: areaSelection)
                }
            } label: {
                // Area mode opens the live selection overlay; full-display just
                // arms a confirm-preview. Camera (if any) previews in both.
                Label(captureAreaEnabled ? "Preview / Select Area" : "Preview",
                      systemImage: captureAreaEnabled ? "crop" : "eye")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(captureAreaEnabled ? false : selectedDisplayID == nil)
            .padding(.top, 4)

            HStack(spacing: 6) {
                Image(systemName: "command")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("Hotkey:")
                Spacer()
                KeyboardShortcuts.Recorder("", name: .toggleRecording)
            }
            .font(.caption)
            .padding(.top, 2)
        }
    }

    /// Full-width two-segment control. Native `.segmented` Picker hugs its
    /// content and centers on macOS, so build it from buttons that each
    /// expand to fill the container.
    private var segmentedToggle: some View {
        HStack(spacing: 2) {
            segment("Full Display", on: false)
            segment("Area", on: true)
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: .infinity)
    }

    private func segment(_ title: String, on value: Bool) -> some View {
        let selected = captureAreaEnabled == value
        return Button {
            captureAreaEnabled = value
        } label: {
            Text(title)
                .font(.callout)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                // Hit region must be the whole filled frame (incl. transparent
                // padding), so put contentShape inside the label, last.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var projectsSection: some View {
        if !projectRows.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Projects")

                if let last = projectRows.last {
                    Button {
                        StudioLauncher.open(bundleURL: last.url)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.rectangle")
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Last recording").font(.callout)
                                Text(projectSubtitle(last))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if !projectRows.recent.isEmpty {
                    dropdown("clock.arrow.circlepath", selection: "Recent",
                             isPresented: $showRecentMenu) {
                        ForEach(projectRows.recent) { item in
                            pickRow(projectSubtitle(item), selected: false) {
                                showRecentMenu = false
                                StudioLauncher.open(bundleURL: item.url)
                            }
                        }
                        Divider().padding(.vertical, 4)
                        pickRow("Clear Recents", selected: false) {
                            showRecentMenu = false
                            recents.clearRecents()
                        }
                    }
                }
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func relativeDate(_ item: ProjectMenuItem) -> String? {
        item.date.map { Self.relativeFormatter.localizedString(for: $0, relativeTo: Date()) }
    }

    private func projectSubtitle(_ item: ProjectMenuItem) -> String {
        relativeDate(item).map { "\(item.title) · \($0)" } ?? item.title
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    @ViewBuilder
    private var captureModeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "crop")
                .frame(width: 16)
                .foregroundStyle(.secondary)
            segmentedToggle
        }
        .frame(maxWidth: .infinity)

        if captureAreaEnabled {
            HStack(spacing: 6) {
                Image(systemName: "selection.pin.in.out")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text("Area")
                Spacer()
                if let r = captureRegion {
                    Text("\(areaDisplayName) · \(Int(r.width))×\(Int(r.height))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                } else {
                    Text("Not set")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.caption)
        }
    }

    /// Full-width dropdown: leading icon + a plain `Button` (which honors
    /// `maxWidth: .infinity`, unlike a `Menu`/`.menu` Picker, both of which hug
    /// their content on macOS). The choice list opens in a popover.
    private func dropdown(_ systemImage: String, selection: String,
                          isPresented: Binding<Bool>,
                          @ViewBuilder content: () -> some View) -> some View {
        let list = content()
        return HStack(spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Button {
                isPresented.wrappedValue.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(selection).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .popover(isPresented: isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    list
                }
                .padding(.vertical, 4)
                .frame(minWidth: 220)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// One selectable row inside a `dropdown` popover.
    private func pickRow(_ title: String, selected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(selected ? 1 : 0)
                Text(title)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Visible label for a device dropdown (camera/mic): selected name or "None".
    private func deviceLabel(_ devices: [AVCaptureDevice], _ id: String?) -> String {
        devices.first { $0.uniqueID == id }?.localizedName ?? "None"
    }

    /// Visible label for the display dropdown.
    private var displayLabel: String {
        guard let d = displays.first(where: { $0.id == selectedDisplayID }) else { return "Display" }
        return "\(d.name) (\(d.pixelWidth)×\(d.pixelHeight))"
    }

    /// Name of the display the saved region was dragged on (for the Area readout).
    private var areaDisplayName: String {
        displays.first { $0.id == captureRegionDisplayID }?.name ?? "Unknown display"
    }

    private var formattedElapsed: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var isRecording: Bool {
        if case .recording = session.state { return true }
        return false
    }

    /// " · <display>" suffix shown under the recording timer, when known.
    private var recordingTargetSuffix: String {
        let id = captureAreaEnabled ? captureRegionDisplayID : selectedDisplayID
        guard let name = displays.first(where: { $0.id == id })?.name else { return "" }
        return " · \(name)"
    }

    private func openRecordingPanel() { StudioLauncher.promptAndOpen() }

    private func refreshDevices() async {
        guard permissionGranted else { return }
        cameras = DeviceDiscovery.cameras()
        microphones = DeviceDiscovery.microphones()
        if selectedCameraID == nil { selectedCameraID = AppSettings.lastCameraID }
        if selectedMicID == nil { selectedMicID = AppSettings.lastMicID }
        if let id = selectedCameraID, !cameras.contains(where: { $0.uniqueID == id }) {
            selectedCameraID = nil
        }
        if let id = selectedMicID, !microphones.contains(where: { $0.uniqueID == id }) {
            selectedMicID = nil
        }
        do {
            let (items, _) = try await DeviceDiscovery.displays()
            displays = items
            if selectedDisplayID == nil { selectedDisplayID = AppSettings.lastDisplayID }
            if selectedDisplayID == nil || !items.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = items.first?.id
            }
        } catch {
            displays = []
            selectedDisplayID = nil
        }
    }
}

/// Equatable trigger for the off-main rows reload (URLs compared by
/// standardized path, never `==`).
private struct ProjectsKey: Equatable {
    let recent: [String]
    let last: String?
    let active: String?
    init(recent: [URL], last: URL?, active: URL?) {
        self.recent = recent.map { $0.standardizedFileURL.path }
        self.last = last?.standardizedFileURL.path
        self.active = active?.standardizedFileURL.path
    }
}

struct ProjectMenuItem: Identifiable, Equatable {
    var id: String { url.standardizedFileURL.path }
    let url: URL
    let title: String
    let date: Date?
}

/// What the popup's Projects section shows. Built off the main thread: it
/// stats bundles and reads meta.json, either of which can block on a slow volume.
struct ProjectMenuRows: Equatable {
    static let empty = ProjectMenuRows(last: nil, recent: [])
    static let recentLimit = 5

    let last: ProjectMenuItem?
    let recent: [ProjectMenuItem]
    var isEmpty: Bool { last == nil && recent.isEmpty }

    /// `activeRecording` (the bundle the session is still writing) is hidden:
    /// Studio would refuse to open it anyway.
    static func load(recent: [URL], last: URL?, activeRecording: URL? = nil,
                     isOpenable: (URL) -> Bool = RecentProjects.isOpenable) -> ProjectMenuRows {
        let activePath = activeRecording?.standardizedFileURL.path
        let isActive = { (url: URL) in url.standardizedFileURL.path == activePath }
        let lastURL = last.flatMap { !isActive($0) && isOpenable($0) ? $0 : nil }
        let recentURLs = RecentProjects.displayable(recent.filter { !isActive($0) },
                                                    excluding: lastURL,
                                                    limit: recentLimit, isOpenable: isOpenable)
        return ProjectMenuRows(last: lastURL.map(item), recent: recentURLs.map(item))
    }

    private static func item(_ url: URL) -> ProjectMenuItem {
        let date = (try? ProjectBundle(url: url).loadMeta().recordedAt)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return ProjectMenuItem(url: url, title: url.deletingPathExtension().lastPathComponent, date: date)
    }
}
