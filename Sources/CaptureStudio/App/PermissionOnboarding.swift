import AppKit
import SwiftUI

/// First-run permission window. Chrome, not content: deliberately NOT
/// registered with `CaptureContentWindows`, so it never appears in screen.mp4.
@MainActor
enum PermissionOnboarding {
    static let windowID = NSUserInterfaceItemIdentifier("chrome.permissionOnboarding")
    private static var controller: NSWindowController?

    static func show() {
        if let window = controller?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: PermissionOnboardingView())
        let window = NSWindow(contentViewController: hosting)
        window.identifier = windowID
        window.title = "Set Up Capture Studio"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        let newController = NSWindowController(window: window)
        controller = newController
        DockPresence.shared.retain()

        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            Task { @MainActor in
                AppSettings.permissionOnboardingDone = true
                if controller?.window === window { controller = nil }
                DockPresence.shared.release()
            }
        }

        newController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func showIfNeeded(isLoginItem: Bool) {
        let center = PermissionCenter.shared
        let coreGranted = center.isGranted(.screenRecording)
            && center.isGranted(.microphone)
            && center.isGranted(.camera)
        if LaunchRouting.shouldShowPermissionOnboarding(
            isLoginItem: isLoginItem,
            onboardingDone: AppSettings.permissionOnboardingDone,
            coreGranted: coreGranted
        ) {
            show()
        } else if coreGranted {
            AppSettings.permissionOnboardingDone = true
        }
    }

    static func close() {
        controller?.window?.performClose(nil)
    }
}

struct PermissionOnboardingView: View {
    @ObservedObject private var center = PermissionCenter.shared

    private struct Row {
        let kind: PermissionKind
        let icon: String
        let detail: String
    }

    private let rows: [Row] = [
        Row(kind: .screenRecording, icon: "rectangle.dashed.badge.record",
            detail: "Required to record your screen and system audio."),
        Row(kind: .microphone, icon: "mic",
            detail: "Optional — record your voice."),
        Row(kind: .camera, icon: "video",
            detail: "Optional — record your webcam alongside the screen."),
        Row(kind: .localNetwork, icon: "wifi",
            detail: "Optional — use your phone as a camera or microphone."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture Studio needs a few permissions")
                .font(.headline)
            Text("You can change these anytime in System Settings → Privacy & Security.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ForEach(rows, id: \.kind) { row in
                permissionRow(row)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { PermissionOnboarding.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func permissionRow(_ row: Row) -> some View {
        let status = center.status(row.kind)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.icon)
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.kind.title).font(.body.weight(.medium))
                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                if row.kind == .screenRecording, status == .denied {
                    Text("After allowing, relaunch Capture Studio so macOS applies it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if row.kind == .localNetwork, status == .unknown {
                    Text("macOS asks the first time Capture Studio looks for your phone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            action(for: row.kind, status: status)
        }
    }

    @ViewBuilder
    private func action(for kind: PermissionKind, status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            Button("Allow") { Task { await center.request(kind) } }
        case .denied:
            HStack {
                Button("Open Settings") { center.openSettings(kind) }
                if kind == .screenRecording {
                    Button("Relaunch") { AppRelauncher.relaunch() }
                        .disabled(!relaunchSafe)
                }
            }
        case .unknown:
            Button("Check") { Task { await center.request(kind) } }
        }
    }

    private var relaunchSafe: Bool {
        guard let session = RecordingSession.shared else { return true }
        return AppRelauncher.isSafe(state: session.state)
    }
}
