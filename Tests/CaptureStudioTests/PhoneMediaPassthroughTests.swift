import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import CaptureStudio

/// Hand-encoded Baseline 1920×1080 parameter sets (no emulation-prevention bytes needed).
/// SPS: profile_idc 66, constraint_set0+1, level_idc 40, sps_id 0, log2_max_frame_num_minus4 0,
///      poc_type 0, log2_max_poc_lsb_minus4 0, max_num_ref_frames 1, gaps 0,
///      pic_width_in_mbs_minus1 119, pic_height_in_map_units_minus1 67, frame_mbs_only 1,
///      direct_8x8_inference 1, frame_cropping 1 (left 0, right 0, top 0, bottom 4 → 1088−8),
///      vui_parameters_present 0, rbsp trailing bits.
/// PPS: pps_id 0, sps_id 0, CAVLC, no slice groups, ref_idx defaults 0, no weighted pred,
///      qp/qs/chroma offsets 0, deblocking_filter_control_present 1, rbsp trailing bits.
let fixtureSPSPPS: [Data] = [
    Data([0x67, 0x42, 0xC0, 0x28, 0xF4, 0x03, 0xC0, 0x11, 0x3F, 0x2A]),
    Data([0x68, 0xCE, 0x3C, 0x80]),
]

@Test func audioFormatParsesASC() throws {
    let asbd = try MediaPassthrough.audioFormat(asc: Data([0x11, 0x88])).audioStreamBasicDescription!
    #expect(asbd.mSampleRate == 48000 && asbd.mChannelsPerFrame == 1 && asbd.mFormatID == kAudioFormatMPEG4AAC && asbd.mFramesPerPacket == 1024)
}
@Test func videoFormatDimensions() throws {
    #expect(MediaPassthrough.dimensions(of: try MediaPassthrough.videoFormat(parameterSets: fixtureSPSPPS)) == CGSize(width: 1920, height: 1080))
}
@Test func nonKeyframeIsMarkedNotSync() throws {
    let fmt = try MediaPassthrough.videoFormat(parameterSets: fixtureSPSPPS)
    let s = try MediaPassthrough.videoSample(VideoFramePayload(ptsNs: 0, keyframe: false, mirrored: false, rotationDeg: 0, nalus: Data([0,0,0,2,0x41,0x00])), format: fmt, pts: .zero)
    let att = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]]
    #expect(att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true)
}
@Test func ptsGateDropsBackward() { var g = PTSGate(); #expect(g.accept(.init(value: 10, timescale: 1)) && !g.accept(.init(value: 9, timescale: 1)) && g.accept(.init(value: 11, timescale: 1))) }
@Test func ptsFloor() { let f = PTSFloor(floor: .init(value: 5, timescale: 1)); #expect(!f.accept(.init(value: 4, timescale: 1)) && f.accept(.init(value: 5, timescale: 1))) }
@Test func rotationLatchKeepsFirst() { var r = RotationLatch(); #expect(r.latch(90) == 90 && r.latch(0) == 90) }
@Test func rotatedSizeSwaps() { #expect(MediaPassthrough.rotatedSize(CGSize(width: 1920, height: 1080), rotationDeg: 90) == CGSize(width: 1080, height: 1920)) }
@Test func transform90MapsIntoPositiveQuadrant() {
    let t = MediaPassthrough.transform(rotationDeg: 90, mirrored: false, size: CGSize(width: 1920, height: 1080))
    let p = CGPoint(x: 1920, y: 0).applying(t)   // top-right corner → bottom-right of the 1080×1920 frame
    #expect(abs(p.x - 1080) < 0.01 && abs(p.y - 1920) < 0.01)
}

// MARK: - Additional behavior checks

@Test func keyframeIsNotMarkedNotSync() throws {
    let fmt = try MediaPassthrough.videoFormat(parameterSets: fixtureSPSPPS)
    let s = try MediaPassthrough.videoSample(VideoFramePayload(ptsNs: 0, keyframe: true, mirrored: false, rotationDeg: 0, nalus: Data([0,0,0,2,0x65,0x00])), format: fmt, pts: CMTime(value: 7, timescale: 30))
    let att = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]]
    #expect((att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false) == false)
    #expect(CMSampleBufferGetPresentationTimeStamp(s) == CMTime(value: 7, timescale: 30))
    #expect(CMSampleBufferGetTotalSampleSize(s) == 6)
}
@Test func audioSampleCarriesTrimAndPTS() throws {
    let fmt = try MediaPassthrough.audioFormat(asc: Data([0x11, 0x88]))
    let pts = CMTime(value: 4800, timescale: 48_000)
    let s = try MediaPassthrough.audioSample(AudioFramePayload(ptsNs: 0, accessUnit: Data([1, 2, 3, 4])), format: fmt, pts: pts, trimAtStart: MediaPassthrough.aacPrimingTrim)
    #expect(CMSampleBufferGetPresentationTimeStamp(s) == pts)
    #expect(CMSampleBufferGetNumSamples(s) == 1)
    #expect(CMSampleBufferGetTotalSampleSize(s) == 4)
    let trim = try #require(CMGetAttachment(s, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) as? NSDictionary)
    #expect(CMTimeMakeFromDictionary(trim as CFDictionary) == MediaPassthrough.aacPrimingTrim)
    let plain = try MediaPassthrough.audioSample(AudioFramePayload(ptsNs: 0, accessUnit: Data([1])), format: fmt, pts: pts, trimAtStart: nil)
    #expect(CMGetAttachment(plain, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) == nil)
}
@Test func previewCopyDisplaysImmediately() throws {
    let fmt = try MediaPassthrough.videoFormat(parameterSets: fixtureSPSPPS)
    let s = try MediaPassthrough.videoSample(VideoFramePayload(ptsNs: 0, keyframe: true, mirrored: false, rotationDeg: 0, nalus: Data([0,0,0,2,0x65,0x00])), format: fmt, pts: .zero)
    let c = try MediaPassthrough.previewCopy(s)
    let att = CMSampleBufferGetSampleAttachmentsArray(c, createIfNecessary: false) as? [[CFString: Any]]
    #expect(att?.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
    let orig = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]]
    #expect(orig?.first?[kCMSampleAttachmentKey_DisplayImmediately] == nil)
}
@Test func esDescriptorWrapsASC() {
    let d = [UInt8](MediaPassthrough.esDescriptor(asc: Data([0x11, 0x88])))
    #expect(d == [0x03, 0x19, 0x00, 0x00, 0x00,
                  0x04, 0x11, 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                  0x05, 0x02, 0x11, 0x88,
                  0x06, 0x01, 0x02])
}
@Test func audioFormatCookieIsESDescriptor() throws {
    let fmt = try MediaPassthrough.audioFormat(asc: Data([0x11, 0x88]))
    var size = 0
    let raw = try #require(CMAudioFormatDescriptionGetMagicCookie(fmt, sizeOut: &size))
    let cookie = [UInt8](UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: size))
    #expect(cookie.first == 0x03 && cookie.suffix(5) == [0x11, 0x88, 0x06, 0x01, 0x02])
}
/// AVAssetWriter must produce an m4a that CoreAudio can open (the bare-ASC cookie bug).
@Test func passthroughAudioFileOpensInCoreAudio() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cs-aac-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    let fmt = try MediaPassthrough.audioFormat(asc: Data([0x11, 0x88]))
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fmt)
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    // One silent AAC-LC mono frame (any syntactically valid AU is fine for the container).
    let au = Data([0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C])
    for i in 0..<5 {
        let s = try MediaPassthrough.audioSample(AudioFramePayload(ptsNs: 0, accessUnit: au), format: fmt,
                                                 pts: CMTime(value: CMTimeValue(i * 1024), timescale: 48_000), trimAtStart: nil)
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        #expect(input.append(s))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    #expect(writer.status == .completed)
    var file: AudioFileID?
    let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file)
    #expect(status == noErr, "AudioFileOpenURL: \(status)")
    if let file { AudioFileClose(file) }
}
@Test func invalidASCThrows() {
    #expect(throws: (any Error).self) { try MediaPassthrough.audioFormat(asc: Data([0x11])) }
}
@Test func emptyParameterSetsThrow() {
    #expect(throws: (any Error).self) { try MediaPassthrough.videoFormat(parameterSets: []) }
}
@Test func transformsMapSourceRectOntoRotatedRect() {
    let size = CGSize(width: 1920, height: 1080)
    for deg: UInt16 in [0, 90, 180, 270] {
        for mirrored in [false, true] {
            let t = MediaPassthrough.transform(rotationDeg: deg, mirrored: mirrored, size: size)
            let r = CGRect(origin: .zero, size: size).applying(t)
            let out = MediaPassthrough.rotatedSize(size, rotationDeg: deg)
            #expect(abs(r.minX) < 0.01 && abs(r.minY) < 0.01 && abs(r.width - out.width) < 0.01 && abs(r.height - out.height) < 0.01)
        }
    }
    // Mirroring swaps left/right: the source origin lands on the right edge for 0°.
    let m = CGPoint.zero.applying(MediaPassthrough.transform(rotationDeg: 0, mirrored: true, size: size))
    #expect(abs(m.x - 1920) < 0.01 && abs(m.y) < 0.01)
}
@Test func previewCopyOfNonKeyframeKeepsNotSync() throws {
    let fmt = try MediaPassthrough.videoFormat(parameterSets: fixtureSPSPPS)
    let s = try MediaPassthrough.videoSample(VideoFramePayload(ptsNs: 0, keyframe: false, mirrored: false, rotationDeg: 0, nalus: Data([0,0,0,2,0x41,0x00])), format: fmt, pts: .zero)
    let c = try MediaPassthrough.previewCopy(s)
    let copyAtt = try #require((CMSampleBufferGetSampleAttachmentsArray(c, createIfNecessary: false) as? [[CFString: Any]])?.first)
    #expect(copyAtt[kCMSampleAttachmentKey_NotSync] as? Bool == true)
    #expect(copyAtt[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
    let origAtt = try #require((CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]])?.first)
    #expect(origAtt[kCMSampleAttachmentKey_NotSync] as? Bool == true)
    #expect(origAtt[kCMSampleAttachmentKey_DisplayImmediately] == nil)
}
@Test func mirroredRotationsFlipInDisplayFrame() {
    let size = CGSize(width: 1920, height: 1080)
    let p90 = CGPoint(x: 1920, y: 0).applying(MediaPassthrough.transform(rotationDeg: 90, mirrored: true, size: size))
    #expect(abs(p90.x - 0) < 0.01 && abs(p90.y - 1920) < 0.01)
    let p270 = CGPoint.zero.applying(MediaPassthrough.transform(rotationDeg: 270, mirrored: true, size: size))
    #expect(abs(p270.x - 1080) < 0.01 && abs(p270.y - 1920) < 0.01)
    // Mirroring is a horizontal flip of the upright (unmirrored) output for every rotation.
    for deg: UInt16 in [0, 90, 180, 270] {
        let plain = MediaPassthrough.transform(rotationDeg: deg, mirrored: false, size: size)
        let mirrored = MediaPassthrough.transform(rotationDeg: deg, mirrored: true, size: size)
        let outW = MediaPassthrough.rotatedSize(size, rotationDeg: deg).width
        for src in [CGPoint(x: 0, y: 0), CGPoint(x: 1920, y: 0), CGPoint(x: 0, y: 1080), CGPoint(x: 1920, y: 1080), CGPoint(x: 300, y: 700)] {
            let a = src.applying(plain), b = src.applying(mirrored)
            #expect(abs(b.x - (outW - a.x)) < 0.01 && abs(b.y - a.y) < 0.01)
        }
    }
}
