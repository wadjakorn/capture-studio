import Foundation
import Testing
@testable import CaptureStudio

@Suite struct LicensePolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let info = LicenseInfo(keyHint: "AB12", email: nil, validatedAt: Date(timeIntervalSince1970: 0))

    @Test func betaAndLicensedUnlockEverything() {
        for status in [LicenseStatus.beta, .licensed(info)] {
            #expect(LicensePolicy.isUnlocked(status, now: now))
            for feature in Feature.allCases {
                #expect(LicensePolicy.allows(feature, status: status, now: now))
            }
        }
    }

    @Test func trialUnlocksUntilExpiry() {
        #expect(LicensePolicy.isUnlocked(.trial(expires: now.addingTimeInterval(1)), now: now))
        #expect(!LicensePolicy.isUnlocked(.trial(expires: now), now: now))
        #expect(!LicensePolicy.isUnlocked(.trial(expires: now.addingTimeInterval(-1)), now: now))
    }

    @Test func unlicensedAndInvalidAreLocked() {
        #expect(!LicensePolicy.allows(.pro, status: .unlicensed, now: now))
        #expect(!LicensePolicy.allows(.pro, status: .invalid(reason: "refunded"), now: now))
    }
}

private actor FakeProvider: LicenseProvider {
    var status: LicenseStatus = .unlicensed
    var activatedKeys: [String] = []

    func currentStatus() async -> LicenseStatus { status }

    func activate(key: String) async throws -> LicenseStatus {
        activatedKeys.append(key)
        guard key == "GOOD-KEY" else { throw LicenseError.invalidKey }
        status = .licensed(LicenseInfo(keyHint: "-KEY", email: nil, validatedAt: Date()))
        return status
    }

    func deactivate() async throws -> LicenseStatus {
        status = .unlicensed
        return status
    }
}

@Suite @MainActor struct LicenseManagerTests {
    @Test func defaultBetaProviderIsUnlocked() async {
        let manager = LicenseManager(provider: BetaLicenseProvider())
        await manager.refresh()
        #expect(manager.status == .beta)
        #expect(manager.allows(.pro))
        await #expect(throws: LicenseError.notAvailableInBeta) {
            try await manager.activate(key: "ANY")
        }
    }

    @Test func activateTrimsKeyAndUnlocks() async throws {
        let provider = FakeProvider()
        let manager = LicenseManager(provider: provider)
        await manager.refresh()
        #expect(!manager.isUnlocked)

        try await manager.activate(key: "  GOOD-KEY\n")
        #expect(manager.isUnlocked)
        #expect(await provider.activatedKeys == ["GOOD-KEY"])

        try await manager.deactivate()
        #expect(!manager.isUnlocked)
    }

    @Test func badOrEmptyKeyKeepsStatus() async {
        let provider = FakeProvider()
        let manager = LicenseManager(provider: provider)
        await manager.refresh()
        await #expect(throws: LicenseError.invalidKey) { try await manager.activate(key: "   ") }
        await #expect(throws: LicenseError.invalidKey) { try await manager.activate(key: "BAD") }
        #expect(manager.status == .unlicensed)
        #expect(await provider.activatedKeys == ["BAD"])   // empty key never reaches the provider
    }
}
