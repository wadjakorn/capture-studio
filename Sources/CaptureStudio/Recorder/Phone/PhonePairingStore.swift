import Foundation
import Security

struct PhonePairing: Codable, Equatable {
    var fingerprint: Data
    var token: Data
    var name: String
}

protocol PairingBackend {
    func read(_ account: String) throws -> Data?
    func write(_ account: String, _ data: Data) throws
    func delete(_ account: String) throws
    func accounts() throws -> [String]
}

enum KeychainError: Error {
    case status(OSStatus)
}

/// Legacy file-based keychain (no data-protection keychain: needs entitlements).
struct KeychainBackend: PairingBackend {
    private static let service = "dev.wadjakorn.capture-studio.phone"

    private func baseQuery(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    func read(_ account: String) throws -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return out as? Data
    }

    func write(_ account: String, _ data: Data) throws {
        let update = SecItemUpdate(baseQuery(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    func accounts() throws -> [String] {
        var q = baseQuery()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        let items = out as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

final class PhonePairingStore: @unchecked Sendable {
    static let shared = PhonePairingStore()

    private let backend: PairingBackend
    private let lock = NSLock()

    init(backend: PairingBackend = KeychainBackend()) {
        self.backend = backend
    }

    func pairing(for phoneID: String) -> PhonePairing? {
        lock.lock(); defer { lock.unlock() }
        do {
            guard let data = try backend.read(phoneID) else { return nil }
            return try JSONDecoder().decode(PhonePairing.self, from: data)
        } catch {
            Log.recorder.error("pairing read failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func save(_ p: PhonePairing, for phoneID: String) throws {
        let data = try JSONEncoder().encode(p)
        lock.lock(); defer { lock.unlock() }
        try backend.write(phoneID, data)
    }

    func forget(_ phoneID: String) {
        lock.lock(); defer { lock.unlock() }
        try? backend.delete(phoneID)
    }

    var hasAnyPairing: Bool {
        lock.lock(); defer { lock.unlock() }
        return !((try? backend.accounts())?.isEmpty ?? true)
    }
}
