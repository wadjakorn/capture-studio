import Foundation
import Testing
@testable import CaptureStudio

@Test func pairingCodeVector() {
    let fp = Data(repeating: 0xAB, count: 32), nm = Data(repeating: 0x01, count: 32), np = Data(repeating: 0x02, count: 32)
    let code = PairingCode.derive(fingerprint: fp, macNonce: nm, phoneNonce: np)
    #expect(code.count == 6 && code.allSatisfy(\.isNumber))
    #expect(code == "601340")
}
@Test func commitmentRoundTrip() {
    let n = Data(repeating: 7, count: 32)
    #expect(PairingCode.verify(commitment: PairingCode.commitment(for: n), nonce: n))
    #expect(!PairingCode.verify(commitment: PairingCode.commitment(for: n), nonce: Data(repeating: 8, count: 32)))
}
@Test func commitmentLengthMismatchFails() {
    let n = Data(repeating: 7, count: 32)
    #expect(!PairingCode.verify(commitment: Data(PairingCode.commitment(for: n).prefix(31)), nonce: n))
}
@Test func formattedCode() { #expect(PairingCode.formatted("483921") == "483 921") }
