import CoreMedia
import Foundation
import Testing
@testable import CaptureStudio

@Test func picksLowRTTSamples() {
    let base: UInt64 = 10_000_000_000
    var s: [ClockSample] = []
    for i in 0..<20 {
        let fast = i >= 15
        s.append(.synthetic(macSendNs: base + UInt64(i) * 1_000_000,
                            offsetNs: fast ? 1_000_000_000 : 999_000_000,
                            rttNs: fast ? 2_000_000 : 50_000_000))
    }
    #expect(ClockSync.offset(samples: s) == 1_000_000_000)
}
@Test func syntheticIsConsistent() {
    let s = ClockSample.synthetic(macSendNs: 10_000_000_000, offsetNs: -3_000_000_000, rttNs: 4_000_000)
    #expect(s.rttNs == 4_000_000 && s.offsetNs == -3_000_000_000)
}
@Test func emptyIsNil() { #expect(ClockSync.offset(samples: []) == nil) }
@Test func mapToHostAddsOffset() { #expect(ClockSync.mapToHost(ptsNs: 5_000_000_000, offsetNs: -1_000_000_000).seconds == 4) }
