import CryptoKit
import Foundation

enum PairingCode {
    static func commitment(for nonce: Data) -> Data {
        Data(SHA256.hash(data: nonce))
    }

    /// Constant-time: no early exit on byte mismatch.
    static func verify(commitment: Data, nonce: Data) -> Bool {
        let expected = Array(SHA256.hash(data: nonce))
        let given = Array(commitment)
        guard given.count == expected.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<expected.count { diff |= expected[i] ^ given[i] }
        return diff == 0
    }

    /// u32BE(SHA-256(fingerprint ‖ macNonce ‖ phoneNonce)[0..<4]) % 1_000_000, zero-padded to 6 digits.
    static func derive(fingerprint: Data, macNonce: Data, phoneNonce: Data) -> String {
        let digest = Array(SHA256.hash(data: fingerprint + macNonce + phoneNonce))
        let value = digest[0..<4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let s = String(value % 1_000_000)
        return String(repeating: "0", count: max(0, 6 - s.count)) + s
    }

    /// "483921" -> "483 921"
    static func formatted(_ code: String) -> String {
        guard code.count > 3 else { return code }
        return code.prefix(3) + " " + code.dropFirst(3)
    }
}
