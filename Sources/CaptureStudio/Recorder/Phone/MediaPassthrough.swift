import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation

enum MediaPassthroughError: Error, Equatable {
    case osStatus(OSStatus)
    case invalidASC
    case noParameterSets
}

/// Builds CoreMedia objects for phone streams that are written without re-encoding
/// (AVAssetWriter passthrough) and previewed via AVSampleBufferDisplayLayer.
/// Video: Baseline H.264, AVCC (4-byte lengths), DTS == PTS. Audio: one AAC access unit per sample.
enum MediaPassthrough {
    /// Encoder priming that AAC encoders prepend (1024 + 1088 frames at 48 kHz).
    static let aacPrimingTrim = CMTime(value: 2112, timescale: 48_000)

    static func videoFormat(parameterSets: [Data]) throws -> CMVideoFormatDescription {
        guard !parameterSets.isEmpty, !parameterSets.contains(where: \.isEmpty) else {
            throw MediaPassthroughError.noParameterSets
        }
        // Keep the bytes alive in contiguous arrays while CoreMedia reads them.
        let arrays = parameterSets.map { [UInt8]($0) }
        var format: CMFormatDescription?
        let status = withPointers(arrays) { pointers in
            let sizes = arrays.map(\.count)
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: arrays.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw MediaPassthroughError.osStatus(status) }
        return format
    }

    static func audioFormat(asc: Data) throws -> CMAudioFormatDescription {
        let config = try parseASC(asc)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: config.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: config.channels,
            mBitsPerChannel: 0,
            mReserved: 0)
        let cookie = [UInt8](asc)
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: raw.count,
                magicCookie: raw.baseAddress,
                extensions: nil,
                formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw MediaPassthroughError.osStatus(status) }
        return format
    }

    static func videoSample(_ f: VideoFramePayload, format: CMVideoFormatDescription, pts: CMTime) throws -> CMSampleBuffer {
        let block = try makeBlockBuffer(f.nalus)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = f.nalus.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw MediaPassthroughError.osStatus(status) }
        if !f.keyframe {
            try setSampleAttachment(sample, key: kCMSampleAttachmentKey_NotSync)
        }
        return sample
    }

    static func audioSample(_ f: AudioFramePayload, format: CMAudioFormatDescription, pts: CMTime, trimAtStart: CMTime?) throws -> CMSampleBuffer {
        let block = try makeBlockBuffer(f.accessUnit)
        var packet = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(f.accessUnit.count))
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            presentationTimeStamp: pts,
            packetDescriptions: &packet,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw MediaPassthroughError.osStatus(status) }
        if let trimAtStart {
            let dict = CMTimeCopyAsDictionary(trimAtStart, allocator: kCFAllocatorDefault)
            CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                            value: dict, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return sample
    }

    /// A copy for the live preview layer, flagged to display without waiting on a timebase.
    static func previewCopy(_ s: CMSampleBuffer) throws -> CMSampleBuffer {
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: s, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw MediaPassthroughError.osStatus(status) }
        try setSampleAttachment(copy, key: kCMSampleAttachmentKey_DisplayImmediately)
        return copy
    }

    /// Writer-input transform for a buffer of pixel `size` that must be rotated clockwise by
    /// `rotationDeg` (CameraX `rotationDegrees`) to display upright, optionally mirrored
    /// horizontally first. Maps the source pixel rect exactly onto (0, 0, rotatedSize).
    static func transform(rotationDeg: UInt16, mirrored: Bool, size: CGSize) -> CGAffineTransform {
        let w = size.width, h = size.height
        let rotation: CGAffineTransform
        switch rotationDeg % 360 {
        case 90:  rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 180: rotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default:  rotation = .identity
        }
        guard mirrored else { return rotation }
        let flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        return flip.concatenating(rotation)   // flip first, then rotate
    }

    static func rotatedSize(_ size: CGSize, rotationDeg: UInt16) -> CGSize {
        switch rotationDeg % 360 {
        case 90, 270: return CGSize(width: size.height, height: size.width)
        default: return size
        }
    }

    static func dimensions(of format: CMVideoFormatDescription) -> CGSize {
        let d = CMVideoFormatDescriptionGetDimensions(format)
        return CGSize(width: Int(d.width), height: Int(d.height))
    }

    // MARK: - Private

    private struct AACConfig { var sampleRate: Float64; var channels: UInt32 }

    private static let sampleRates: [Float64] = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
    ]

    /// AudioSpecificConfig: 5-bit audioObjectType (31 = escape), 4-bit samplingFrequencyIndex
    /// (15 = explicit 24-bit rate), 4-bit channelConfiguration.
    private static func parseASC(_ asc: Data) throws -> AACConfig {
        var reader = BitReader(bytes: [UInt8](asc))
        guard let aot = reader.read(5) else { throw MediaPassthroughError.invalidASC }
        if aot == 31 { guard reader.read(6) != nil else { throw MediaPassthroughError.invalidASC } }
        guard let index = reader.read(4) else { throw MediaPassthroughError.invalidASC }
        let rate: Float64
        if index == 15 {
            guard let explicit = reader.read(24), explicit > 0 else { throw MediaPassthroughError.invalidASC }
            rate = Float64(explicit)
        } else {
            guard Int(index) < sampleRates.count else { throw MediaPassthroughError.invalidASC }
            rate = sampleRates[Int(index)]
        }
        guard let channels = reader.read(4), channels > 0 else { throw MediaPassthroughError.invalidASC }
        return AACConfig(sampleRate: rate, channels: channels == 7 ? 8 : channels)
    }

    private struct BitReader {
        let bytes: [UInt8]
        var pos = 0
        mutating func read(_ n: Int) -> UInt32? {
            guard pos + n <= bytes.count * 8 else { return nil }
            var v: UInt32 = 0
            for _ in 0..<n {
                v = (v << 1) | UInt32((bytes[pos >> 3] >> (7 - UInt8(pos & 7))) & 1)
                pos += 1
            }
            return v
        }
    }

    /// A block buffer that owns its own copy of `data`.
    private static func makeBlockBuffer(_ data: Data) throws -> CMBlockBuffer {
        guard !data.isEmpty else { throw MediaPassthroughError.osStatus(kCMBlockBufferEmptyBBufErr) }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw MediaPassthroughError.osStatus(status) }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: raw.count)
        }
        guard status == noErr else { throw MediaPassthroughError.osStatus(status) }
        return block
    }

    /// Sets `key = true` on the first sample's attachment dictionary.
    private static func setSampleAttachment(_ s: CMSampleBuffer, key: CFString) throws {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: true),
              CFArrayGetCount(array) > 0 else {
            throw MediaPassthroughError.osStatus(kCMSampleBufferError_RequiredParameterMissing)
        }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(key).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    private static func withPointers<R>(_ arrays: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        func recurse(_ i: Int, _ acc: [UnsafePointer<UInt8>]) -> R {
            if i == arrays.count { return body(acc) }
            return arrays[i].withUnsafeBufferPointer { recurse(i + 1, acc + [$0.baseAddress!]) }
        }
        return recurse(0, [])
    }
}

/// Drops any timestamp not strictly after the last accepted one.
struct PTSGate {
    private var last: CMTime?
    mutating func accept(_ pts: CMTime) -> Bool {
        if let last, pts <= last { return false }
        last = pts
        return true
    }
}

/// Accepts timestamps at or after `floor`.
struct PTSFloor {
    let floor: CMTime
    func accept(_ pts: CMTime) -> Bool { pts >= floor }
}

/// Remembers the first rotation it sees; later values are ignored (the writer transform is fixed).
struct RotationLatch {
    private(set) var value: UInt16?
    mutating func latch(_ deg: UInt16) -> UInt16 {
        if let value { return value }
        value = deg
        return deg
    }
}
