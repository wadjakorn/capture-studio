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
    @State private var captureAreaEnabled = AppSettings.captureAreaEnabled
    @State private var captureRegion: CGRect? = AppSettings.captureRegion
    @State private var captureRegionDisplayID: CGDirectDisplayID? = AppSettings.captureRegionDisplayID
    @State private var permissionGranted = Permissions.screenRecordingGranted()
    @State private var elapsed: TimeInterval = 0
    @State private var showDisplayMenu = false
    @State private var showCameraMenu = false
    @State private var showMicMenu = false

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

            Divider()

            HStack {
                Button {
                    openRecordingPanel()
                } label: {
                    Label("Open", systemImage: "folder.badge.plus")
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(ProjectBundle.defaultRecordingsDirectory())
                } label: {
                    Label("Folder", systemImage: "folder")
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
        .onChange(of: selectedDisplayID) { _, id in AppSettings.lastDisplayID = id }
        .onChange(of: selectedCameraID) { _, id in AppSettings.lastCameraID = id }
        .onChange(of: selectedMicID) { _, id in AppSettings.lastMicID = id }
        .onChange(of: systemAudioEnabled) { _, on in AppSettings.recordSystemAudio = on }
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
            Label(session.counting ? "Starting…" : "Sources ready", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(session.counting ? Color.secondary : Color.green)
            HStack {
                Button {
                    Task { await session.startCountdownThenBegin(displayID: selectedDisplayID) }
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.counting)

                Button("Cancel") {
                    Task { await session.cancelCountdownOrArming() }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
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

            Button {
                elapsed = 0
                // Area mode records the dragged screen; full mode the picker's.
                let region = captureAreaEnabled ? captureRegion : nil
                let useDisplay = captureAreaEnabled ? captureRegionDisplayID : selectedDisplayID
                Task {
                    await session.toggle(displayID: useDisplay,
                                         cameraID: selectedCameraID,
                                         micID: selectedMicID,
                                         systemAudio: systemAudioEnabled,
                                         region: region,
                                         activateForPrompts: false,
                                         previewFirst: true)
                }
            } label: {
                // Every mode arms first (preview): camera shows its live preview,
                // area shows the region outline, full-display just confirms.
                Label("Preview", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(captureAreaEnabled
                      ? (captureRegion == nil || captureRegionDisplayID == nil)
                      : selectedDisplayID == nil)
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
                Button {
                    Task {
                        if let (r, did) = await AreaSelector.selectRegion() {
                            captureRegion = r
                            captureRegionDisplayID = did
                        }
                    }
                } label: {
                    Text(captureRegion == nil ? "Select Area…" : "Reselect Area…")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
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

    private func openRecordingPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ProjectBundle.defaultRecordingsDirectory()
        panel.allowedContentTypes = [.package]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              url.pathExtension == ProjectBundle.pathExtension else { return }
        StudioLauncher.open(bundleURL: url)
    }

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
