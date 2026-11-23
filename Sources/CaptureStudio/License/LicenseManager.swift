import Combine
import Foundation

/// App-wide license state. UI observes `status`; feature gates call
/// `allows(_:)`.
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager(provider: BetaLicenseProvider())

    /// Starts unlocked-as-beta so nothing flickers locked before `refresh()`.
    @Published private(set) var status: LicenseStatus = .beta

    private let provider: any LicenseProvider
    private let now: @Sendable () -> Date

    init(provider: any LicenseProvider, now: @escaping @Sendable () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    var isUnlocked: Bool { LicensePolicy.isUnlocked(status, now: now()) }

    func allows(_ feature: Feature) -> Bool {
        LicensePolicy.allows(feature, status: status, now: now())
    }

    /// Reload from the provider (cache / server). Call at launch.
    func refresh() async {
        status = await provider.currentStatus()
    }

    func activate(key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LicenseError.invalidKey }
        status = try await provider.activate(key: trimmed)
    }

    func deactivate() async throws {
        status = try await provider.deactivate()
    }
}
