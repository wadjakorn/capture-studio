import AppKit
import SwiftUI
import Combine

/// Pure rules for the capture-issue toasts. Non-isolated so tests call it directly.
enum IssueToastPolicy {
    /// Warnings in `current` not yet shown: the appended suffix when `current`
    /// extends `previous`, otherwise all of `current` (a new arm reset the list).
    static func newWarnings(previous: [String], current: [String]) -> [String] {
        if current.starts(with: previous) {
            return Array(current.dropFirst(previous.count))
        }
        return current
    }

    /// A failure after writers were on lost (part of) a take; anything earlier
    /// — `.preparing` included, where nothing was recorded yet — never started.
    static func failureTitle(previous: RecordingSession.State) -> String {
        switch previous {
        case .recording, .finishing: return "Recording stopped early"
        case .idle, .arming, .armed, .preparing, .failed: return "Can't start recording"
        }
    }

    /// At most `max` lines; overflow collapses into a trailing "and N more".
    static func visibleLines(_ lines: [String], max: Int = 3) -> [String] {
        guard lines.count > max else { return lines }
        let kept = Swift.max(max - 1, 0)
        return Array(lines.prefix(kept)) + ["and \(lines.count - kept) more"]
    }
}

/// Top-center toast for a failed start, an early stop, or a capture warning.
/// Chrome: never registered with `CaptureContentWindows`.
@MainActor
enum IssueToast {
    private static let toast = ToastPanel(identifier: "chrome.issueToast",
                                          placement: .topCenter, lifetime: 8)

    static func show(title: String, lines: [String], isError: Bool, fix: PermissionKind?) {
        let view = IssueToastView(
            title: title,
            lines: IssueToastPolicy.visibleLines(lines),
            isError: isError,
            onFix: fix.map { kind in
                {
                    Task { await PermissionCenter.shared.fix(kind) }
                    dismiss()
                }
            },
            onClose: { dismiss() },
            onHover: { toast.setHovering($0) })
        toast.show(view)
    }

    static func dismiss() {
        toast.dismiss()
    }
}

private struct IssueToastView: View {
    let title: String
    let lines: [String]
    let isError: Bool
    let onFix: (() -> Void)?
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isError ? Color.red : Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onFix {
                    Button("Fix…", action: onFix)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onHover(perform: onHover)
    }
}

/// Surfaces session problems the user might not otherwise see — a hotkey start
/// that failed, a recording that stopped early, a source lost mid-take — as an
/// `IssueToast`. Started once from `RecordingSession.init()`.
@MainActor
final class SessionIssueNotifier {
    static let shared = SessionIssueNotifier()

    private weak var session: RecordingSession?
    private var cancellables = Set<AnyCancellable>()
    private var lastWarnings: [String] = []
    private var lastState: RecordingSession.State = .idle

    /// Idempotent for the same session.
    func start(session: RecordingSession) {
        guard self.session !== session else { return }
        cancellables.removeAll()
        self.session = session
        lastWarnings = session.warnings
        lastState = session.state
        // @Published sinks fire in willSet: use only the delivered value, never
        // re-read `session.warnings` / `session.state` here.
        session.$warnings
            .dropFirst()
            .sink { [weak self] warnings in self?.warningsChanged(to: warnings) }
            .store(in: &cancellables)
        session.$state
            .dropFirst()
            .sink { [weak self] state in self?.stateChanged(to: state) }
            .store(in: &cancellables)
    }

    private func warningsChanged(to current: [String]) {
        let new = IssueToastPolicy.newWarnings(previous: lastWarnings, current: current)
        lastWarnings = current
        // The popup lists warnings itself.
        guard !new.isEmpty, !TrayPopupOpener.isPopupOpen() else { return }
        IssueToast.show(title: "Recording issue", lines: new, isError: false,
                        fix: new.lazy.compactMap(PermissionPreflight.kind(forMessage:)).first)
    }

    private func stateChanged(to state: RecordingSession.State) {
        let previous = lastState
        lastState = state
        // Every delivered failure is a new one (`.failed → .failed` included,
        // e.g. a repeated hotkey press). Never suppressed by the popup check:
        // the GUI closes the popup right before starting, and it can still
        // read as visible while it animates out.
        guard case .failed(let message) = state else { return }
        // `fail()` assigns failurePermission before state, so it is current here.
        IssueToast.show(title: IssueToastPolicy.failureTitle(previous: previous),
                        lines: [message], isError: true, fix: session?.failurePermission)
    }
}
