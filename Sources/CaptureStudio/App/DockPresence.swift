import AppKit

/// Ref-counted Dock presence. Cold launch is dockless (LSUIElement); every
/// window that wants a Dock tile (Studio, Dashboard) retains, and the app only
/// reverts to menu-bar-only when the last one releases.
@MainActor
final class DockPresence {
    static let shared = DockPresence(apply: { NSApp.setActivationPolicy($0) })

    private let apply: (NSApplication.ActivationPolicy) -> Void
    private var count = 0

    init(apply: @escaping (NSApplication.ActivationPolicy) -> Void) {
        self.apply = apply
    }

    func retain() {
        count += 1
        if count == 1 { apply(.regular) }
    }

    /// Unbalanced releases are ignored rather than going negative.
    func release() {
        guard count > 0 else { return }
        count -= 1
        if count == 0 { apply(.accessory) }
    }
}
