import CoreMedia
import Foundation

/// One CLOCK_PING/PONG round trip. All timestamps are nanoseconds on their own clock
/// (mac = host clock, phone = BOOTTIME).
struct ClockSample: Equatable {
    var macSendNs: UInt64
    var phoneRecvNs: UInt64
    var phoneSendNs: UInt64
    var macRecvNs: UInt64
    /// (macRecv − macSend) − (phoneSend − phoneRecv)
    var rttNs: UInt64
    /// ((macSend + macRecv)/2) − ((phoneRecv + phoneSend)/2), phone→Mac.
    var offsetNs: Int64

    init(macSendNs: UInt64, phoneRecvNs: UInt64, phoneSendNs: UInt64, macRecvNs: UInt64) {
        self.macSendNs = macSendNs
        self.phoneRecvNs = phoneRecvNs
        self.phoneSendNs = phoneSendNs
        self.macRecvNs = macRecvNs
        let total = Int64(truncatingIfNeeded: macRecvNs) - Int64(truncatingIfNeeded: macSendNs)
        let phone = Int64(truncatingIfNeeded: phoneSendNs) - Int64(truncatingIfNeeded: phoneRecvNs)
        self.rttNs = UInt64(max(0, total - phone))
        let macMid = (Int64(truncatingIfNeeded: macSendNs) + Int64(truncatingIfNeeded: macRecvNs)) / 2
        let phoneMid = (Int64(truncatingIfNeeded: phoneRecvNs) + Int64(truncatingIfNeeded: phoneSendNs)) / 2
        self.offsetNs = macMid - phoneMid
    }

    /// Test helper: consistent sample from an intended offset and RTT, phone processing 0.
    static func synthetic(macSendNs: UInt64, offsetNs: Int64, rttNs: UInt64) -> ClockSample {
        let phone = Int64(truncatingIfNeeded: macSendNs) + Int64(rttNs / 2) - offsetNs
        let p = UInt64(truncatingIfNeeded: phone)
        return ClockSample(macSendNs: macSendNs, phoneRecvNs: p, phoneSendNs: p, macRecvNs: macSendNs + rttNs)
    }
}

enum ClockSync {
    /// Median offset of the `keep` lowest-RTT samples; nil if empty. For an even count
    /// the lower-middle element is used.
    static func offset(samples: [ClockSample], keep: Int = 5) -> Int64? {
        guard !samples.isEmpty, keep > 0 else { return nil }
        let best = samples.sorted { $0.rttNs < $1.rttNs }.prefix(keep)
        let offsets = best.map(\.offsetNs).sorted()
        return offsets[(offsets.count - 1) / 2]
    }

    /// Maps a phone PTS (ns) to host time. Int64 math; negative offsets are fine.
    static func mapToHost(ptsNs: UInt64, offsetNs: Int64) -> CMTime {
        CMTime(value: Int64(truncatingIfNeeded: ptsNs) &+ offsetNs, timescale: 1_000_000_000)
    }

    static let slowRTTThresholdNs: UInt64 = 100_000_000
}
