import SwiftUI
import AVFoundation
import AppKit

struct RecorderMenuView: View {
    @EnvironmentObject private var session: RecordingSession

    @State private var displays: [DisplayItem] = []
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var cameras: [AVCaptureDevice] = []
    @State private var selectedCameraID: String?
    @State private var microphones: [AVCaptureDevice] = []
    @State private var selectedMicID: String?
    @State private var systemAudioEnabled = AppSettings.recordSystemAudio
    @State private var permissionGranted = Permissions.screenRecordingGranted()
    @State private var elapsed: TimeInterval = 0
    @State private var counting = false
    @State private var countdownTask: Task<Void, Never>?

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture Studio")
                .font(.headline)

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
                Button("Open Recording…") { openRecordingPanel() }
                Button("Recordings Folder") {
                    NSWorkspace.shared.open(ProjectBundle.defaultRecordingsDirectory())
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
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
            VStack(alignment: .leading, spacing: 8) {
                Label(formattedElapsed, systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3.monospacedDigit())
                Button("Stop Recording") {
                    Task { await session.stop() }
                }
                .keyboardShortcut(.escape, modifiers: [])
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
            Label(counting ? "Starting…" : "Sources ready", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(counting ? Color.secondary : Color.green)
            HStack {
                Button {
                    let displayID = selectedDisplayID
                    counting = true
                    countdownTask = Task {
                        await CountdownOverlay.run(seconds: AppSettings.countdownSeconds,
                                                   displayID: displayID)
                        guard !Task.isCancelled else { return }
                        await session.beginRecording()
                        counting = false
                    }
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(counting)

                Button("Cancel") {
                    countdownTask?.cancel()
                    countdownTask = nil
                    counting = false
                    Task { await session.cancelArming() }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledPicker("Display", systemImage: "display") {
                Picker("Display", selection: $selectedDisplayID) {
                    ForEach(displays) { display in
                        Text("\(display.name) (\(display.pixelWidth)×\(display.pixelHeight))")
                            .tag(Optional(display.id))
                    }
                }
            }

            labeledPicker("Camera", systemImage: "video") {
                Picker("Camera", selection: $selectedCameraID) {
                    Text("None").tag(String?.none)
                    ForEach(cameras, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
            }

            labeledPicker("Microphone", systemImage: "mic") {
                Picker("Microphone", selection: $selectedMicID) {
                    Text("None").tag(String?.none)
                    ForEach(microphones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Toggle("System Audio", isOn: $systemAudioEnabled)
            }

            Button {
                guard let displayID = selectedDisplayID else { return }
                elapsed = 0
                let cameraID = selectedCameraID
                let micID = selectedMicID
                let systemAudio = systemAudioEnabled
                Task {
                    var camera = cameraID
                    var mic = micID
                    if camera != nil, await !Permissions.requestCapture(.video) { camera = nil }
                    if mic != nil, await !Permissions.requestCapture(.audio) { mic = nil }
                    await session.arm(displayID: displayID, cameraID: camera,
                                      micID: mic, systemAudio: systemAudio)
                }
            } label: {
                Label("Preview", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedDisplayID == nil)

            Button("Refresh Devices") {
                Task { await refreshDevices() }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func labeledPicker(_ title: String, systemImage: String,
                               @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            content()
                .labelsHidden()
        }
    }

    private var formattedElapsed: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
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
