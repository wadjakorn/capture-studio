import Foundation
import Testing
@testable import CaptureStudio

final class InMemoryPairingBackend: PairingBackend {
    var items: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { items[account] }
    func write(_ account: String, _ data: Data) throws { items[account] = data }
    func delete(_ account: String) throws { items[account] = nil }
    func accounts() throws -> [String] { Array(items.keys) }
}

private func sample(_ name: String = "Pixel") -> PhonePairing {
    PhonePairing(fingerprint: Data([1, 2, 3]), token: Data(repeating: 7, count: 32), name: name)
}

@Test func pairingStoreSaveReadForget() throws {
    let store = PhonePairingStore(backend: InMemoryPairingBackend())
    #expect(!store.hasAnyPairing)
    try store.save(sample(), for: "phone-1")
    #expect(store.pairing(for: "phone-1") == sample())
    #expect(store.hasAnyPairing)
    store.forget("phone-1")
    #expect(store.pairing(for: "phone-1") == nil)
    #expect(!store.hasAnyPairing)
}

@Test func pairingStoreOverwriteReplaces() throws {
    let store = PhonePairingStore(backend: InMemoryPairingBackend())
    try store.save(sample("Old"), for: "p")
    try store.save(sample("New"), for: "p")
    #expect(store.pairing(for: "p")?.name == "New")
}

@Test func pairingStoreUnknownIDIsNil() {
    let store = PhonePairingStore(backend: InMemoryPairingBackend())
    #expect(store.pairing(for: "nope") == nil)
}
