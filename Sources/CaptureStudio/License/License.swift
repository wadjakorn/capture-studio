import Foundation

// License layer: the single place the app asks "may this user use X?".
//
// Today (free beta) the provider is `BetaLicenseProvider`, which unlocks
// everything. When paid tiers ship, add a provider backed by the store's
// license API (Lemon Squeezy / Paddle: activate, validate, deactivate), cache
// the result in the Keychain for offline use, and swap it in at
// `LicenseManager.shared`. Call sites (`allows(_:)`) do not change.
//
// Deliberately not DRM: a non-sandboxed Mac app can always be patched. The
// goal is an honest, convenient path for people who want to pay.

/// Gated capabilities. One tier for now; split into finer cases (e.g. per
/// export option) once pricing is decided, and gate each call site with
/// `LicenseManager.shared.allows(_:)`.
enum Feature: String, CaseIterable, Sendable {
    /// Anything in the paid tier.
    case pro
}

struct LicenseInfo: Equatable, Codable, Sendable {
    /// Last few characters of the key, for display ("••••-AB12"). The full key
    /// belongs in the Keychain, never in this struct or in logs.
    var keyHint: String
    var email: String?
    /// Last successful online validation; used to allow an offline grace period.
    var validatedAt: Date
}

enum LicenseStatus: Equatable, Codable, Sendable {
    /// Free beta: everything unlocked, no key needed.
    case beta
    case trial(expires: Date)
    case licensed(LicenseInfo)
    case unlicensed
    /// Key rejected (refunded, revoked, activation limit reached…).
    case invalid(reason: String)
}

enum LicenseError: LocalizedError, Equatable {
    case notAvailableInBeta
    case invalidKey
    case activationLimitReached
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notAvailableInBeta: "Capture Studio is free during the beta — no license key needed."
        case .invalidKey: "That license key isn't valid."
        case .activationLimitReached: "This license key is already active on the maximum number of Macs."
        case .network(let message): "Couldn't reach the license server: \(message)"
        }
    }
}

/// Pure decision logic, kept separate so it is unit-testable.
enum LicensePolicy {
    static func isUnlocked(_ status: LicenseStatus, now: Date) -> Bool {
        switch status {
        case .beta, .licensed: true
        case .trial(let expires): now < expires
        case .unlicensed, .invalid: false
        }
    }

    static func allows(_ feature: Feature, status: LicenseStatus, now: Date) -> Bool {
        switch feature {
        case .pro: isUnlocked(status, now: now)
        }
    }
}

/// Backend for license state. Implementations talk to the store's API and
/// own persistence (Keychain); `currentStatus()` must work offline from cache.
protocol LicenseProvider: Sendable {
    func currentStatus() async -> LicenseStatus
    func activate(key: String) async throws -> LicenseStatus
    func deactivate() async throws -> LicenseStatus
}

/// Free-beta provider: always `.beta` (everything unlocked).
struct BetaLicenseProvider: LicenseProvider {
    func currentStatus() async -> LicenseStatus { .beta }
    func activate(key: String) async throws -> LicenseStatus { throw LicenseError.notAvailableInBeta }
    func deactivate() async throws -> LicenseStatus { .beta }
}
