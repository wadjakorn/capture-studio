import Foundation
import AppKit
import AVFoundation
import Combine

/// Live status of every permission the app needs, refreshed on app activation and
/// whenever Local Network detection changes.
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    @Published private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    private var cancellables = Set<AnyCancellable>()

    init() {
        refresh()
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)
        // @Published sinks fire in willSet; hop to the next main-queue turn so
        // refresh() reads the new value.
        PhoneBrowser.shared.$localNetworkDenied
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)
        PhoneBrowser.shared.$hasSeenPhone
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)
    }

    func status(_ kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .unknown
    }

    func isGranted(_ kind: PermissionKind) -> Bool {
        status(kind) == .granted
    }

    func refresh() {
        let screenGranted = Permissions.screenRecordingGranted()
        // Upgraders who granted before the flag existed must read .denied (not
        // .notDetermined) if they later revoke.
        if screenGranted { AppSettings.screenRecordingRequested = true }
        var next: [PermissionKind: PermissionStatus] = [
            .screenRecording: .screen(preflight: screenGranted,
                                      requestedBefore: AppSettings.screenRecordingRequested),
            .camera: .fromAV(AVCaptureDevice.authorizationStatus(for: .video)),
            .microphone: .fromAV(AVCaptureDevice.authorizationStatus(for: .audio)),
        ]
        next[.localNetwork] = .localNetwork(policyDenied: PhoneBrowser.shared.localNetworkDenied,
                                            hasSeenPhone: PhoneBrowser.shared.hasSeenPhone)
        if next != statuses { statuses = next }
    }

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .screenRecording:
            AppSettings.screenRecordingRequested = true
            Permissions.requestScreenRecording()
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .localNetwork:
            PhoneBrowser.shared.start()  // the OS prompts on first browse
        }
        refresh()
    }

    func fix(_ kind: PermissionKind) async {
        // The cached status can be stale (e.g. a camera/mic prompt just denied
        // during a start); re-requesting a denied grant shows no UI at all.
        refresh()
        switch status(kind) {
        case .notDetermined, .unknown: await request(kind)
        case .denied:
            // Granted-but-pending-relaunch also reads .denied; the onboarding
            // window (behind Settings) is where Relaunch lives.
            if kind == .screenRecording { PermissionOnboarding.show() }
            openSettings(kind)
        case .granted:
            // Fix was offered, so something still looks off — never a silent no-op.
            openSettings(kind)
        }
    }

    func openSettings(_ kind: PermissionKind) {
        Permissions.openSettings(kind)
    }
}
