import Foundation
import Testing
@testable import CaptureStudio

@Test func roundTripTwoMessagesAndPartialTail() throws {
    let a = PhoneMessage(type: .stop, payload: Data())
    let b = PhoneMessage(type: .audioFrame, payload: Data([1, 2, 3]))
    var buf = PhoneFraming.encode(a) + PhoneFraming.encode(b) + Data([0x0E, 0x00])
    #expect(try PhoneFraming.decode(&buf) == [a, b])
    #expect(buf == Data([0x0E, 0x00]))
}
@Test func headerIsBigEndian() {
    let d = PhoneFraming.encode(PhoneMessage(type: .videoFrame, payload: Data(count: 258)))
    #expect(Array(d.prefix(5)) == [14, 0, 0, 1, 2])
}
@Test func unknownTypeThrows() {
    var buf = Data([200, 0, 0, 0, 0])
    #expect(throws: (any Error).self) { try PhoneFraming.decode(&buf) }
}
@Test func oversizeThrows() {
    var buf = Data([14, 0xFF, 0xFF, 0xFF, 0xFF])
    #expect(throws: (any Error).self) { try PhoneFraming.decode(&buf) }
}
@Test func videoFramePayloadRoundTrip() {
    let p = VideoFramePayload(ptsNs: 123_456_789, keyframe: true, mirrored: true, rotationDeg: 90, nalus: Data([0, 0, 0, 1, 0x65]))
    #expect(VideoFramePayload(p.encoded) == p)
}
@Test func videoConfigRoundTrip() {
    let p = VideoConfigPayload(parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3])])
    #expect(VideoConfigPayload(p.encoded) == p)
}
@Test func clockPongLayout() {
    let p = ClockPongPayload(macSendHostNs: 1, phoneRecvNs: 2, phoneSendNs: 3)
    #expect(p.encoded.count == 24 && ClockPongPayload(p.encoded) == p)
}
@Test func audioFramePayloadRoundTripOnSlice() {
    let p = AudioFramePayload(ptsNs: 42, accessUnit: Data([9, 8, 7]))
    let padded = Data([0xAA, 0xBB]) + p.encoded
    #expect(AudioFramePayload(padded.dropFirst(2)) == p)
}
@Test func shortPayloadsReturnNil() {
    #expect(VideoFramePayload(Data(count: 10)) == nil)
    #expect(AudioFramePayload(Data(count: 7)) == nil)
    #expect(ClockPongPayload(Data(count: 23)) == nil)
    #expect(VideoConfigPayload(Data([2, 0, 1, 0x67])) == nil)
}
