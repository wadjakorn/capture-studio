import SwiftUI

/// Thin Dashboard bar shown only while Screen Recording is not granted.
/// Mic/camera denial is a deliberate choice; the per-take preflight covers it.
struct PermissionBanner: View {
    @ObservedObject private var permissions = PermissionCenter.shared

    nonisolated static func message(status: (PermissionKind) -> PermissionStatus) -> String? {
        status(.screenRecording) == .granted
            ? nil
            : "Screen Recording is off — Capture Studio can't record your screen."
    }

    var body: some View {
        if let text = Self.message(status: permissions.status) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(text).font(.callout)
                Spacer()
                Button("Set Up…") { PermissionOnboarding.show() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }
}
