# Phone Companion (Android camera/mic over Wi-Fi) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Our own Android app streams camera + mic to Capture Studio over Wi-Fi; the phone shows up in the recorder pickers and records as main video, front camera, or microphone with no third-party app and no adb.

**Architecture:** Phone = Bonjour-advertised TLS server (AndroidKeyStore identity) streaming Baseline H.264 (AVCC) + AAC with BOOTTIME timestamps. Mac = `NWBrowser` + pinned `NWConnection`, commitment-based pairing, clock-offset estimation, and a `PhoneStreamRecorder` that writes passthrough into `AVAssetWriter` (lazy writer at the first post-Record keyframe) and previews via `AVSampleBufferDisplayLayer`. `CameraRecorder` and `PhoneStreamRecorder` share `CameraSourceRecorder`; `RecordingSession` picks by id prefix.

**Tech Stack:** Mac: Swift (CLT, Swift 5 mode), Network.framework, Security, CryptoKit, CoreMedia, AVFoundation, swift-testing 0.12.0. Android: Kotlin 2.0, Compose, CameraX 1.3, MediaCodec, NsdManager, JUnit 4.

**Spec:** `docs/superpowers/specs/2026-11-04-phone-companion-design.md` (v2)

**Prerequisite:** Part B of `docs/superpowers/plans/2026-11-04-phone-camera-and-main-source.md` (Tasks 6–10) merged, including its two amendments: `makeComposition` honors `preferredTransform`; camera candidate ids come from `RecordingSession.availableCameraIDs()`.

## Global Constraints

- Mac: no new package dependencies. macOS 15+. `Resources/Info.plist`: `NSLocalNetworkUsageDescription`, `NSBonjourServices = ["_capturestudio._tcp"]`.
- Android: `android/` in repo, Gradle wrapper committed (incl. `gradle-wrapper.jar`), AGP 8.5, Kotlin 2.0 + `org.jetbrains.kotlin.plugin.compose`, compileSdk/targetSdk 34, **minSdk 30**, CameraX 1.3.4. `local.properties` gitignored.
- Protocol exactly as the spec table (types 1–19), `type: UInt8, length: UInt32 BE`, max payload 8 MiB, protocol major 1.
- Video invariants: Baseline, no B-frames, DTS == PTS, strictly increasing PTS, no inline SPS/PPS in frames, one `VIDEO_CONFIG` per START.
- Phone clock: BOOTTIME (`elapsedRealtimeNanos`) for PONG, video, audio.
- Pairing: commitment flow; `code = u32BE(SHA256(F ‖ N_M ‖ N_P)[0..<4]) % 1_000_000` zero-padded 6 digits; confirm on phone; 120 s timeout.
- Writing: lazy writer at first keyframe with `hostPTS ≥ beginHostNs`; transform set before `startWriting`; NotSync on non-keyframes; never drop for `isReadyForMoreMediaData`.
- Commits need explicit user confirmation.

## Review Focus

1. Wi-Fi drop mid-recording → video (and riding mic) finalize with `truncated: true`; recording saves. Task 9 `didFail` + Task 14 manual.
2. Frame captured before Record but arriving after → must be dropped (`PTSFloor`), else 100–300 ms desync. Pure test Task 4; manual lip-sync Task 14.
3. Mac and phone pairing codes must agree byte-for-byte → shared vector Task 3 (Swift) / Task 11 (Kotlin), and the commitment check rejects a wrong reveal (Task 11 test).
4. Portrait phone → file has a 90° `preferredTransform`, Studio renders upright, `writtenPixelSize` post-rotation. Task 4 transform test + Part B amendment + Task 14.
5. Second authenticated Mac while streaming → `ERROR busy`; an unauthenticated socket never blocks the phone. Task 12 `Session`; manual Task 14.

---

## File map

| File | Responsibility |
|---|---|
| `Sources/CaptureStudio/Recorder/Phone/PhoneProtocol.swift` | `PhoneMessageType`, `PhoneFraming`, payload structs |
| `Sources/CaptureStudio/Recorder/Phone/ClockSync.swift` | `ClockSample`, `ClockSync` |
| `Sources/CaptureStudio/Recorder/Phone/PairingCode.swift` | SAS derivation + commitment helpers |
| `Sources/CaptureStudio/Recorder/Phone/PhoneDevice.swift` | `PhoneDevice`, `PhoneDeviceID` |
| `Sources/CaptureStudio/Recorder/Phone/PhonePairingStore.swift` | keychain store behind `PairingBackend` |
| `Sources/CaptureStudio/Recorder/Phone/PhoneBrowser.swift` | `NWBrowser` → `@Published phones`, lazy policy |
| `Sources/CaptureStudio/Recorder/Phone/PhoneConnection.swift` | TLS pin + message loop + control continuations |
| `Sources/CaptureStudio/Recorder/Phone/MediaPassthrough.swift` | format descriptions, sample builders, `PTSGate`, `PTSFloor`, `RotationLatch` |
| `Sources/CaptureStudio/Recorder/Phone/PhoneStreamRecorder.swift` | `CameraSourceRecorder` over a connection |
| `Sources/CaptureStudio/Recorder/CameraSourceRecorder.swift` | protocol, `PreviewSurface`, `CameraSourceResult` |
| `Sources/CaptureStudio/Recorder/CameraRecorder.swift` | adopt protocol |
| `Sources/CaptureStudio/App/CameraPreviewPanel.swift` | take `PreviewSurface` |
| `Sources/CaptureStudio/App/PairingPanel.swift` | floating pairing-code panel |
| `Sources/CaptureStudio/Recorder/RecordingSession.swift` | factory, `phoneMicRecorder`, `pendingRecorder`, `availableCameraIDs`, pairing prompt |
| `Sources/CaptureStudio/Recorder/PickerRow.swift`, `App/RecorderMenuView.swift`, `Recorder/DeviceDiscovery.swift` | row model + "Phone (Wi-Fi)" group |
| `Resources/Info.plist` | local network keys |
| `android/app/src/main/java/dev/wadjakorn/capturestudio/phone/*.kt` | companion app |
| `Tests/CaptureStudioTests/Phone*Tests.swift` | pure tests |
| `README.md`, `RELEASING.md` | docs |

---

## Part 1 — Mac pure core

### Task 1: Protocol framing

**Files:** Create `Recorder/Phone/PhoneProtocol.swift`; Test `Tests/CaptureStudioTests/PhoneFramingTests.swift`.

**Interfaces (Produces):**
```swift
enum PhoneMessageType: UInt8 { case hello = 1, auth, authOK, authFail, pairCommit, pairNonce, pairReveal, pairOK, pairDenied,
    clockPing, clockPong, start, videoConfig, videoFrame, audioConfig, audioFrame, keyframeReq, stop, error }
struct PhoneMessage: Equatable { var type: PhoneMessageType; var payload: Data }
enum PhoneFraming {
    static let maxPayload = 8 * 1024 * 1024
    static func encode(_ m: PhoneMessage) -> Data
    /// Drains complete messages from `buffer`, leaving a partial tail. Throws on unknown type / oversize.
    static func decode(_ buffer: inout Data) throws -> [PhoneMessage]
}
struct VideoConfigPayload: Equatable { var parameterSets: [Data]; init?(_ data: Data); var encoded: Data }   // u8 count, (u16 len, bytes)*
struct VideoFramePayload: Equatable { var ptsNs: UInt64; var keyframe: Bool; var mirrored: Bool; var rotationDeg: UInt16; var nalus: Data
    init?(_ data: Data); var encoded: Data }
struct AudioFramePayload: Equatable { var ptsNs: UInt64; var accessUnit: Data; init?(_ data: Data); var encoded: Data }
struct ClockPongPayload: Equatable { var macSendHostNs: UInt64; var phoneRecvNs: UInt64; var phoneSendNs: UInt64; init?(_ data: Data); var encoded: Data }
struct StartConfig: Codable, Equatable { var video: Bool; var audio: Bool; var facing: String; var width: Int; var height: Int; var fps: Int; var bitrate: Int }
struct HelloPayload: Codable, Equatable { var pv: Int; var deviceName: String; var model: String; var caps: [String] }
struct ErrorPayload: Codable, Equatable { var code: String; var message: String }
```

- [ ] **Step 1: Failing tests**
```swift
@Test func roundTripTwoMessagesAndPartialTail() throws {
    let a = PhoneMessage(type: .stop, payload: Data())
    let b = PhoneMessage(type: .audioFrame, payload: Data([1,2,3]))
    var buf = PhoneFraming.encode(a) + PhoneFraming.encode(b) + Data([0x0E, 0x00])
    #expect(try PhoneFraming.decode(&buf) == [a, b])
    #expect(buf == Data([0x0E, 0x00]))
}
@Test func headerIsBigEndian() {
    let d = PhoneFraming.encode(PhoneMessage(type: .videoFrame, payload: Data(count: 258)))
    #expect(Array(d.prefix(5)) == [14, 0, 0, 1, 2])
}
@Test func unknownTypeThrows() { var buf = Data([200, 0,0,0,0]); #expect(throws: (any Error).self) { try PhoneFraming.decode(&buf) } }
@Test func oversizeThrows() { var buf = Data([14, 0xFF,0xFF,0xFF,0xFF]); #expect(throws: (any Error).self) { try PhoneFraming.decode(&buf) } }
@Test func videoFramePayloadRoundTrip() {
    let p = VideoFramePayload(ptsNs: 123_456_789, keyframe: true, mirrored: true, rotationDeg: 90, nalus: Data([0,0,0,1,0x65]))
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
```
- [ ] **Step 2:** `swift test --filter PhoneFramingTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(phone): protocol message framing`.

### Task 2: Clock offset estimator

**Files:** Create `Recorder/Phone/ClockSync.swift`; Test `PhoneClockSyncTests.swift`.

**Interfaces (Produces):**
```swift
struct ClockSample: Equatable {
    var macSendNs: UInt64; var phoneRecvNs: UInt64; var phoneSendNs: UInt64; var macRecvNs: UInt64
    var rttNs: UInt64          // (macRecv − macSend) − (phoneSend − phoneRecv)
    var offsetNs: Int64        // ((macSend + macRecv)/2) − ((phoneRecv + phoneSend)/2), computed in Int64
    /// Test helper: builds a consistent sample from an intended offset and RTT, phone processing 0.
    static func synthetic(macSendNs: UInt64, offsetNs: Int64, rttNs: UInt64) -> ClockSample
}
enum ClockSync {
    static func offset(samples: [ClockSample], keep: Int = 5) -> Int64?     // median of `keep` lowest-RTT; nil if empty
    static func mapToHost(ptsNs: UInt64, offsetNs: Int64) -> CMTime        // timescale 1_000_000_000
    static let slowRTTThresholdNs: UInt64 = 100_000_000
}
```

- [ ] **Step 1: Failing tests**
```swift
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
```
- [ ] **Step 2:** FAIL. **Step 3:** Implement (`synthetic`: `phoneRecv = phoneSend = macSend + rtt/2 − offset` using Int64 math, `macRecv = macSend + rtt`). **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(phone): clock offset estimation`.

### Task 3: Pairing code + device ids

**Files:** Create `Recorder/Phone/PairingCode.swift`, `Recorder/Phone/PhoneDevice.swift`; Test `PhonePairingCodeTests.swift`, `PhoneDeviceIDTests.swift`.

**Interfaces (Produces):**
```swift
enum PairingCode {
    static func commitment(for nonce: Data) -> Data                                   // SHA-256
    static func verify(commitment: Data, nonce: Data) -> Bool                         // constant-time compare
    /// u32BE(SHA-256(fingerprint ‖ macNonce ‖ phoneNonce)[0..<4]) % 1_000_000, zero-padded to 6 digits.
    static func derive(fingerprint: Data, macNonce: Data, phoneNonce: Data) -> String
    static func formatted(_ code: String) -> String                                   // "483 921"
}
struct PhoneDevice: Identifiable, Equatable { let id: String; var name: String; var protocolMajor: Int; var endpoint: NWEndpoint }
enum PhoneDeviceID {
    static func camera(_ id: String) -> String      // "phone:" + id
    static func mic(_ id: String) -> String         // "phone-mic:" + id
    static func phoneID(fromCamera: String) -> String?
    static func phoneID(fromMic: String) -> String?
}
```

- [ ] **Step 1: Failing tests**
```swift
@Test func pairingCodeVector() {
    let fp = Data(repeating: 0xAB, count: 32), nm = Data(repeating: 0x01, count: 32), np = Data(repeating: 0x02, count: 32)
    let code = PairingCode.derive(fingerprint: fp, macNonce: nm, phoneNonce: np)
    #expect(code.count == 6 && code.allSatisfy(\.isNumber))
    #expect(code == "<FREEZE ON FIRST RUN — same literal goes into android PairingCodeTest.kt>")
}
@Test func commitmentRoundTrip() {
    let n = Data(repeating: 7, count: 32)
    #expect(PairingCode.verify(commitment: PairingCode.commitment(for: n), nonce: n))
    #expect(!PairingCode.verify(commitment: PairingCode.commitment(for: n), nonce: Data(repeating: 8, count: 32)))
}
@Test func formatted() { #expect(PairingCode.formatted("483921") == "483 921") }
@Test func idPrefixes() {
    #expect(PhoneDeviceID.phoneID(fromCamera: "phone:abc") == "abc")
    #expect(PhoneDeviceID.phoneID(fromMic: "phone:abc") == nil)
    #expect(PhoneDeviceID.phoneID(fromMic: "phone-mic:abc") == "abc")
}
```
- [ ] **Step 2:** FAIL. **Step 3:** Implement with CryptoKit; freeze the vector literal in both test files. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(phone): commitment-based pairing code and device ids`.

### Task 4: Passthrough media helpers

**Files:** Create `Recorder/Phone/MediaPassthrough.swift`; Test `PhoneMediaPassthroughTests.swift` (hard-code a known x264 1920×1080 Baseline SPS/PPS pair as the fixture — no dependency on later tasks).

**Interfaces (Produces):**
```swift
enum MediaPassthrough {
    static func videoFormat(parameterSets: [Data]) throws -> CMVideoFormatDescription       // nalUnitHeaderLength 4
    static func audioFormat(asc: Data) throws -> CMAudioFormatDescription                   // ASBD from ASC + magic cookie
    static func videoSample(_ f: VideoFramePayload, format: CMVideoFormatDescription, pts: CMTime) throws -> CMSampleBuffer   // NotSync on non-keyframes
    static func audioSample(_ f: AudioFramePayload, format: CMAudioFormatDescription, pts: CMTime, trimAtStart: CMTime?) throws -> CMSampleBuffer // CMAudioSampleBufferCreateReadyWithPacketDescriptions
    static func previewCopy(_ s: CMSampleBuffer) throws -> CMSampleBuffer                   // copy + DisplayImmediately
    static func transform(rotationDeg: UInt16, mirrored: Bool, size: CGSize) -> CGAffineTransform   // rotation ‖ translation into positive quadrant
    static func rotatedSize(_ size: CGSize, rotationDeg: UInt16) -> CGSize
    static func dimensions(of format: CMVideoFormatDescription) -> CGSize
    static let aacPrimingTrim = CMTime(value: 2112, timescale: 48_000)
}
struct PTSGate { mutating func accept(_ pts: CMTime) -> Bool }            // drop pts ≤ last accepted
struct PTSFloor { let floor: CMTime; func accept(_ pts: CMTime) -> Bool } // pts ≥ floor
struct RotationLatch { mutating func latch(_ deg: UInt16) -> UInt16; var value: UInt16? }
```

- [ ] **Step 1: Failing tests**
```swift
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
```
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(phone): passthrough sample buffer builders`.

## Part 2 — Mac networking + recorder

### Task 5: Recorder abstraction + preview surface

**Files:** Create `Recorder/CameraSourceRecorder.swift`; Modify `Recorder/CameraRecorder.swift` (adopt; `Result` → `CameraSourceResult` with optional `camera`), `App/CameraPreviewPanel.swift:20-70,121-140`, `Recorder/RecordingSession.swift` (property types + every `cameraRecorder`/`mainCameraRecorder` site from Part B: `arm`, `beginRecording`, `stop`, `tearDownArmed`, `tearDownForQuit`).

**Interfaces (Produces):** exactly the protocol, `PreviewSurface`, and `CameraSourceResult` in the spec "Recorder abstraction" section. `onDeviceLost` is `(@Sendable (String) -> Void)?` to match Part B's `CameraRecorder`.

- [ ] **Step 1:** Add protocol + `CameraSourceResult`. `CameraRecorder.stop()` returns `CameraSourceResult(camera: track, mic: micTrack)`; `warmUpWarnings` = `[]`.
- [ ] **Step 2:** `CameraPreviewPanel.init(surface: PreviewSurface, onDisplay:placement:onCancel:)`. `.captureSession` keeps `AVCaptureVideoPreviewLayer` + the existing `connection.isVideoMirrored` mirror path. `.displayLayer` hosts the `AVSampleBufferDisplayLayer` and mirrors by transforming that sublayer only (button untouched).
- [ ] **Step 3:** `RecordingSession`: recorder properties typed `(any CameraSourceRecorder)?`; `stop()` handles `result.camera == nil`. Append `warmUpWarnings` to `warnings` after each `warmUp()`.
- [ ] **Step 4:** `swift build` + `swift test` → OK. Manual: local camera preview, mirror toggle, record still work.
- [ ] **Step 5:** Commit `refactor(recorder): CameraSourceRecorder protocol and PreviewSurface`.

### Task 6: `PhoneBrowser` + Info.plist + lazy policy

**Files:** Create `Recorder/Phone/PhoneBrowser.swift`; Modify `Resources/Info.plist`, `App/RecorderMenuView.swift` (start on appear when `PhonePairingStore.hasAnyPairing`).

**Interfaces (Produces):**
```swift
@MainActor final class PhoneBrowser: ObservableObject {
    static let shared: PhoneBrowser
    static let serviceType = "_capturestudio._tcp"
    @Published private(set) var phones: [PhoneDevice]
    @Published private(set) var isBrowsing: Bool
    func start(); func stop()
    func device(id: String) -> PhoneDevice?
    /// Starts if needed and waits ≤ timeout for the id (hotkey path).
    func waitForDevice(id: String, timeout: Duration) async -> PhoneDevice?
}
```
- [ ] **Step 1:** Info.plist keys (description: "Capture Studio finds Capture Studio Phone on your Wi-Fi to use your phone as a camera and microphone.").
- [ ] **Step 2:** Implement with `NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: .tcp)`; TXT `id`/`name`/`pv` from `result.metadata`; results without `id` ignored.
- [ ] **Step 3:** `swift build` → OK. Commit `feat(phone): Bonjour browser for Capture Studio Phone`.

### Task 7: `PhonePairingStore` (keychain)

**Files:** Create `Recorder/Phone/PhonePairingStore.swift`; Test `PhonePairingStoreTests.swift` (in-memory backend).

**Interfaces (Produces):**
```swift
struct PhonePairing: Codable, Equatable { var fingerprint: Data; var token: Data; var name: String }
protocol PairingBackend { func read(_ account: String) throws -> Data?; func write(_ account: String, _ data: Data) throws; func delete(_ account: String) throws; func accounts() throws -> [String] }
struct KeychainBackend: PairingBackend   // kSecClassGenericPassword, service "dev.wadjakorn.capture-studio.phone"
final class PhonePairingStore { static let shared: PhonePairingStore; init(backend: PairingBackend = KeychainBackend())
    func pairing(for phoneID: String) -> PhonePairing?; func save(_ p: PhonePairing, for phoneID: String) throws; func forget(_ phoneID: String); var hasAnyPairing: Bool }
```
- [ ] **Step 1: Failing test:** save → read equal → `hasAnyPairing` → forget → nil. **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(phone): keychain pairing store`.

### Task 8: `PhoneConnection`

**Files:** Create `Recorder/Phone/PhoneConnection.swift`.

**Interfaces (Produces):**
```swift
protocol PhoneConnectionDelegate: AnyObject {   // on `connection.queue`
    func phoneConnection(_ c: PhoneConnection, videoConfig: VideoConfigPayload)
    func phoneConnection(_ c: PhoneConnection, videoFrame: VideoFramePayload)
    func phoneConnection(_ c: PhoneConnection, audioConfig asc: Data)
    func phoneConnection(_ c: PhoneConnection, audioFrame: AudioFramePayload)
    func phoneConnection(_ c: PhoneConnection, didFail message: String)
}
enum PhoneConnectionError: LocalizedError, Equatable {
    case notReachable, identityChanged, pairingDenied, pairingTimedOut, authFailed, busy, versionMismatch(Int), cancelled, network(String)
}
final class PhoneConnection {
    let queue = DispatchQueue(label: "capturestudio.phone.connection")
    weak var delegate: PhoneConnectionDelegate?
    init(device: PhoneDevice, pairing: PhonePairing?, macName: String)
    func connect() async throws -> Data                                   // presented fingerprint; pinned when `pairing` exists → identityChanged on mismatch
    /// HELLO/HELLO, then AUTH (paired) or the commit/nonce/reveal pairing flow. `onCode` fires once the code is known. Returns a new token when pairing happened.
    func authenticate(onCode: @escaping @Sendable (String) -> Void) async throws -> Data?
    func syncClock(samples: Int = 20) async throws -> (offsetNs: Int64, minRTTNs: UInt64)
    func start(_ config: StartConfig) async throws
    func requestKeyframe()
    func stop() async
    func close()                                                           // cancels pending continuations with .cancelled
}
```
- [ ] **Step 1:** TLS: `NWProtocolTLS.Options`, `sec_protocol_options_set_min_tls_protocol_version(.TLSv12)`, verify block → `sec_trust_copy_ref` → `SecTrustCopyCertificateChain` leaf → `SecCertificateCopyData` → SHA-256. `NWParameters` with TCP keepalive enabled. Nonces via `SecRandomCopyBytes`. Receive loop appends and drains with `PhoneFraming.decode`. Control replies via `CheckedContinuation` keyed by expected type: 10 s timeout, **120 s for `pairOK`/`pairDenied`**; `close()` resumes all with `.cancelled`. `ERROR` payload codes map to `.busy` / `.versionMismatch` / `.pairingDenied`.
- [ ] **Step 2:** `swift build` → OK. Commit `feat(phone): TLS connection and control protocol client`.

### Task 9: `PhoneStreamRecorder`

**Files:** Create `Recorder/Phone/PhoneStreamRecorder.swift`.

**Interfaces (Produces):**
```swift
final class PhoneStreamRecorder: CameraSourceRecorder, PhoneConnectionDelegate {
    init(device: PhoneDevice, video: Bool, audio: Bool, facing: String, outputURL: URL?, micOutputURL: URL?,
         pairingStore: PhonePairingStore, onPairingCode: @escaping @Sendable (String?) -> Void)   // nil clears the prompt
}
```
- Consumes: Tasks 1–5, 7, 8.

- [ ] **Step 1:** `warmUp()`: `connect()`; `authenticate(onCode:)` (save `PhonePairing` on token; `onPairingCode(nil)` when done); `syncClock()` → store `offsetNs`; `minRTT > slowRTTThresholdNs` → append to `warmUpWarnings`; `start(StartConfig(video:audio:facing:width:1920,height:1080,fps:30,bitrate:8_000_000))`. `previewSurface = video ? .displayLayer(layer) : nil`.
- [ ] **Step 2:** Delegate (connection queue): `videoConfig` → format description + `dimensions` (second config during writing → warning, ignored); `videoFrame` → `hostPTS = ClockSync.mapToHost`; always enqueue `previewCopy` on the layer (set the layer transform from `rotationDeg`/`mirrored`; `.failed` → `flush()` + recreate); if `shouldWrite` and no writer yet: require `PTSFloor(beginHostNs)` and `keyframe`, then create writer + passthrough input (`outputSettings: nil, sourceFormatHint:`), `input.transform = transform(rotationDeg:mirrored:size:)`, `RotationLatch`, `startWriting`, `startSession(atSourceTime: hostPTS)`, `sessionStartHostTime = hostPTS.seconds`, `writtenPixelSize = rotatedSize(...)`; then `PTSGate` → enqueue into a bounded 2 s buffer drained by `requestMediaDataWhenReady` (overflow → `truncated`, warning). `audioFrame`: same floor; first accepted AU anchors `audioStartHostTime` and carries `trimAtStart: aacPrimingTrim`.
- [ ] **Step 3:** `beginWriting()`: `beginHostNs = host now`, `shouldWrite = true`, `connection.requestKeyframe()`. No writer created here.
- [ ] **Step 4:** `stop()`: `connection.stop()`, drain buffers, finish writers, `CameraSourceResult(camera: video ? TrackInfo(type: .camera, codec: "h264", deviceName: device.name, deviceID: PhoneDeviceID.camera(device.id), truncated:) : nil, mic: …codec "aac", deviceID: PhoneDeviceID.mic(device.id))`. No samples → `camera: nil` + warning. `discard()`: close + cancel writers. `didFail` → `markTruncated`, `onDeviceLost("Phone disconnected.")`.
- [ ] **Step 5:** `swift build` → OK. Commit `feat(phone): PhoneStreamRecorder with passthrough writing and preview`.

### Task 10: RecordingSession + pickers + pairing panel

**Files:** Create `Recorder/PickerRow.swift`, `App/PairingPanel.swift`; Modify `Recorder/RecordingSession.swift` (`arm`, `beginRecording`, `stop`, `tearDownArmed`, `tearDownForQuit`, `toggleFromHotkey`, `availableCameraIDs`), `Recorder/MainSource.swift` (`RecorderSelection.phonePlan`), `Recorder/DeviceDiscovery.swift` (`grouped` → `[PickerRow]`), `App/RecorderMenuView.swift`.

**Interfaces (Produces):**
```swift
struct PickerRow: Identifiable, Equatable { var id: String; var name: String; var kind: DeviceKind; var enabled: Bool = true; var hint: String? = nil }
extension DeviceKind { case phoneWiFi }   // group title "Phone (Wi-Fi)"
extension DeviceDiscovery {
    static func cameraRows(local: [AVCaptureDevice], phones: [PhoneDevice], browsing: Bool) -> [(kind: DeviceKind, rows: [PickerRow])]
    static func micRows(local: [AVCaptureDevice], phones: [PhoneDevice], browsing: Bool) -> [(kind: DeviceKind, rows: [PickerRow])]
}
struct PhonePlan: Equatable { var mainPhone: String?; var overlayPhone: String?; var micPhone: String?; var micHost: MicHost }
enum MicHost: Equatable { case mainRecorder, overlayRecorder, standalonePhone, local, none }
extension RecorderSelection { static func phonePlan(main: MainSource, cameraID: String?, micID: String?) -> PhonePlan }
extension RecordingSession {
    func availableCameraIDs() -> [String]        // local uniqueIDs + PhoneDeviceID.camera for each browsed phone
    @Published var pairingPrompt: PairingPrompt?  // struct PairingPrompt { var phoneName: String; var code: String }
    private var phoneMicRecorder: PhoneStreamRecorder?
    private var pendingRecorder: (any CameraSourceRecorder)?
}
```

- [ ] **Step 1: Failing tests** (`RecorderSelectionTests`, `PickerRowTests`):
```swift
@Test func phoneMicRidesOnSamePhoneVideo() {
    let p = RecorderSelection.phonePlan(main: .camera(uniqueID: "phone:A"), cameraID: nil, micID: "phone-mic:A")
    #expect(p.mainPhone == "A" && p.micPhone == "A" && p.micHost == .mainRecorder)
}
@Test func phoneMicAloneIsStandalone() { #expect(RecorderSelection.phonePlan(main: .display(1), cameraID: nil, micID: "phone-mic:A").micHost == .standalonePhone) }
@Test func phoneVideoLocalMic() { let p = RecorderSelection.phonePlan(main: .display(1), cameraID: "phone:A", micID: "builtin"); #expect(p.overlayPhone == "A" && p.micHost == .local) }
@Test func differentPhonesRejected() { #expect(RecorderSelection.phonePlan(main: .camera(uniqueID: "phone:A"), cameraID: nil, micID: "phone-mic:B").micHost == .none) }
@Test func phoneRowsShowFindHintWhenIdle() {
    let g = DeviceDiscovery.cameraRows(local: [], phones: [], browsing: false)
    #expect(g.first { $0.kind == .phoneWiFi }?.rows.first?.id == "phone-find")
}
@Test func versionMismatchDisabled() {
    let d = PhoneDevice(id: "A", name: "Galaxy", protocolMajor: 2, endpoint: .hostPort(host: "1.2.3.4", port: 1))
    let row = DeviceDiscovery.cameraRows(local: [], phones: [d], browsing: true).first { $0.kind == .phoneWiFi }!.rows[0]
    #expect(row.id == "phone:A" && !row.enabled && row.hint == "Update required")
}
```
- [ ] **Step 2:** FAIL. **Step 3:** Implement `phonePlan`, row builders, `PickerRow`; migrate `RecorderMenuView` pickers (Part B Task 10) to rows; "Find phones…" row (`id: "phone-find"`) starts the browser; empty-while-browsing hint "Open Capture Studio Phone on your Android device".
- [ ] **Step 4:** `arm`: factory `makeCameraSource(id:outputURL:micDevice:micOutputURL:phoneAudio:) -> any CameraSourceRecorder` returning `PhoneStreamRecorder` when `PhoneDeviceID.phoneID(fromCamera:)` matches (device from `PhoneBrowser.shared.device(id:)`, else throw `.notReachable`), **before** the `AVCaptureDevice` lookup. Hold it in `pendingRecorder` across `await warmUp()`; `tearDownArmed` discards `pendingRecorder`. `.local` plan → `warmUpStandaloneMic`. `.standalonePhone` → `phoneMicRecorder = PhoneStreamRecorder(video: false, audio: true, outputURL: nil, micOutputURL: bundle.micURL)` handled in `beginRecording` (beside the `micRecorder` block), `stop` (beside the `micRecorder` block and the nil-out), `tearDownArmed` (detach + discard), `tearDownForQuit` (close). `.none` → warning "Use one phone for both video and microphone." `onPairingCode` → `pairingPrompt`.
- [ ] **Step 5:** `toggleFromHotkey`: for a `phone:` main, `await PhoneBrowser.shared.waitForDevice(id:, timeout: .seconds(3))`; nil → `.failed("Phone not found. Open Capture Studio Phone on your device.")`. Part B's resolver call sites use `availableCameraIDs()`.
- [ ] **Step 6:** `PairingPanel`: floating non-activating panel, bottom-center of `NSScreen.main`, text "Confirm **483 921** on <phone>", Cancel → `cancelArming()`. Shown while `pairingPrompt != nil`.
- [ ] **Step 7:** `identityChanged` at arm → warning "<phone> has a new identity. Forget it in the picker and pair again." + a "Forget" row action in the Phone group calling `PhonePairingStore.forget`.
- [ ] **Step 8:** `swift build` + `swift test` → OK. Commit `feat(recorder): phone camera and mic as recording sources`.

## Part 3 — Android app

### Task 11: Scaffold + protocol + pairing (unit-tested)

**Files:** Create `android/` (`settings.gradle.kts`, `build.gradle.kts`, `gradle/wrapper/*` incl. jar, `gradlew`, `app/build.gradle.kts`, manifest), `MessageCodec.kt`, `Messages.kt`, `PairingCode.kt`, `AnnexB.kt`; tests `MessageCodecTest.kt`, `PairingCodeTest.kt`, `AnnexBTest.kt`. `.gitignore`: `android/.gradle`, `android/**/build`, `android/local.properties`.

- [ ] **Step 1:** Scaffold. Wrapper: download `gradle-8.7-bin.zip`, unzip to a temp dir, run its `bin/gradle wrapper --gradle-version 8.7` inside `android/`, commit the generated files. AGP 8.5.x, Kotlin 2.0.x + Compose plugin, Compose BOM, CameraX 1.3.4 (`camera-core`, `camera-camera2`, `camera-lifecycle`), JUnit 4. `local.properties` → `sdk.dir=/Users/wadjakorntonsri/Library/Android/sdk`.
- [ ] **Step 2: Failing tests:** framing round-trip + partial tail; header `[14,0,0,1,2]`; oversize rejected; pairing vector literal from Task 3; `verifyCommitment` rejects a wrong reveal; Annex-B `00 00 00 01 67 … 00 00 00 01 68 … 00 00 00 01 65 …` → `(sps, pps)` extracted and frame bytes → AVCC with types 7/8 removed.
- [ ] **Step 3:** `./gradlew testDebugUnitTest` → FAIL. **Step 4:** Implement (`MessageDigest` SHA-256, `ByteBuffer` BE, `MessageDigest.isEqual` for the commitment). **Step 5:** PASS.
- [ ] **Step 6:** Commit `feat(android): project scaffold, protocol codec, pairing code, Annex-B conversion`.

### Task 12: Server, pairing, clock, streaming service

**Files:** `Identity.kt`, `Advertiser.kt`, `TlsServer.kt`, `Session.kt`, `PairingStore.kt`, `PhoneClock.kt`, `VideoPipeline.kt`, `AudioPipeline.kt`, `StreamService.kt`, manifest (`CAMERA`, `RECORD_AUDIO`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CAMERA`, `FOREGROUND_SERVICE_MICROPHONE`, `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `WAKE_LOCK`, `POST_NOTIFICATIONS`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`; service `foregroundServiceType="camera|microphone"`).

- [ ] **Step 1:** `Identity`: `KeyPairGenerator("EC", "AndroidKeyStore")`, alias `capturestudio-phone`, `KeyGenParameterSpec(PURPOSE_SIGN)` + `setDigests(DIGEST_NONE, DIGEST_SHA256, DIGEST_SHA384, DIGEST_SHA512)`, `setCertificateSubject("CN=Capture Studio Phone")`, 10-year validity, no user auth. Fingerprint = SHA-256(cert DER). `KeyManagerFactory.getInstance(defaultAlgorithm).init(androidKeyStore, null)` → `SSLContext("TLS")` → `SSLServerSocket(0)`.
- [ ] **Step 2:** `Advertiser`: `NsdServiceInfo` type `_capturestudio._tcp`, name `Build.MODEL`, port, `setAttribute("id"|"name"|"pv")`; `id` UUID persisted once. Unregister in `onDestroy`.
- [ ] **Step 3:** `Session`: accept loop; unauthenticated sockets closed after 10 s; HELLO/HELLO (`pv` mismatch → `ERROR version`); AUTH → `MessageDigest.isEqual(SHA-256(token), stored)`; pairing: `PAIR_COMMIT` → reply `PAIR_NONCE` → on `PAIR_REVEAL` verify commitment (fail → `PAIR_DENIED`) → compute code → `StateFlow` to UI → Allow → token (`SecureRandom` 32) → store hash + Mac name → `PAIR_OK`; an authenticated session is the occupant; another authenticated client → `ERROR busy`. `CLOCK_PING` → `PONG` with `elapsedRealtimeNanos()` at receive and send. `START` → pipelines; `KEYFRAME_REQ` → `codec.setParameters(PARAMETER_KEY_REQUEST_SYNC_FRAME)`; `STOP`/close → pipelines stop. `setKeepAlive(true)`.
- [ ] **Step 4:** `PhoneClock`: read `SENSOR_INFO_TIMESTAMP_SOURCE` via `Camera2CameraInfo.from(cameraInfo).getCameraCharacteristic`; `REALTIME` → identity; `UNKNOWN` → `offset = min over 5 of (elapsedRealtimeNanos() − System.nanoTime())` sampled at START; `toBoottime(ns)`.
- [ ] **Step 5:** `VideoPipeline`: CameraX `Preview` bound to the service's `LifecycleRegistry`; in `setSurfaceProvider { request -> }`: configure `MediaCodec("video/avc")` with `request.resolution`, `KEY_PROFILE AVCProfileBaseline`, `KEY_LEVEL AVCLevel41`, `KEY_MAX_B_FRAMES 0`, `KEY_BIT_RATE 8_000_000`, `KEY_FRAME_RATE 30`, `KEY_I_FRAME_INTERVAL 1`, `COLOR_FormatSurface`; `request.provideSurface(codec.createInputSurface(), executor) { codec.release() }`; `setTransformationInfoListener` → `rotationDeg`; `mirrored = facing == front`. Output: `BUFFER_FLAG_CODEC_CONFIG` → `VIDEO_CONFIG(sps, pps)`; others → strip 7/8, Annex-B → AVCC, `ptsNs = PhoneClock.toBoottime(presentationTimeUs * 1000)`, keyframe from `BUFFER_FLAG_KEY_FRAME`. Release order: surface-request result callback before `codec.release()`.
- [ ] **Step 6:** `AudioPipeline`: `AudioRecord(VOICE_RECOGNITION, 48000, MONO, PCM_16BIT)`; after start, `getTimestamp(ts, TIMEBASE_BOOTTIME)` → `ptsNs(frame) = ts.nanoTime + (frame − ts.framePosition) * 1e9/48000`; AAC-LC encoder (`KEY_AAC_PROFILE AACObjectLC`, 128 kbps); config buffer → `AUDIO_CONFIG`, AUs → `AUDIO_FRAME`.
- [ ] **Step 7:** `StreamService`: `startForeground(type camera|microphone)` only after permissions granted, started from the visible activity; `LifecycleRegistry` CREATED→STARTED on start; partial wake lock + `WifiLock(WIFI_MODE_FULL_LOW_LATENCY)` while streaming; notification with Stop; `onDestroy` unregisters NSD, closes sockets, releases locks.
- [ ] **Step 8:** `./gradlew assembleDebug` → OK; install on the Galaxy for development (`adb install`, dev only).
- [ ] **Step 9:** Commit `feat(android): TLS server, pairing, clock sync and H.264/AAC streaming`.

### Task 13: Android UI

**Files:** `MainActivity.kt`, Compose screens.

- [ ] **Step 1:** Onboarding: request camera, mic, notifications; request battery-optimization exemption (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) with a one-line explanation; then start `StreamService`.
- [ ] **Step 2:** Status card from `Session` state; facing toggle + resolution (720p/1080p), disabled while streaming; keep-screen-on switch (`FLAG_KEEP_SCREEN_ON`). No camera preview.
- [ ] **Step 3:** Pairing dialog "483 921 — MacBook Pro" Allow/Deny; "Paired computers" with Revoke.
- [ ] **Step 4:** `./gradlew assembleDebug` → OK; phone appears in the Mac picker within 2 s after "Find phones…".
- [ ] **Step 5:** Commit `feat(android): companion app UI`.

## Part 4 — Verification + release

### Task 14: End-to-end on a Galaxy

- [ ] **Step 1:** Record the Galaxy model + One UI version + `SENSOR_INFO_TIMESTAMP_SOURCE` value in the spec "Test hardware" section.
- [ ] **Step 2:** Same Wi-Fi; "Find phones…" → phone listed. First arm → codes match → Allow → live preview on the Mac.
- [ ] **Step 3:** Phone main + MacBook front camera + phone mic, 60 s clap test → Studio: clap and flash within ±1 frame; portrait upright; export OK. Measure the AAC lead/lag and adjust `aacPrimingTrim` if off by > 10 ms.
- [ ] **Step 4:** Display main + phone front camera + local mic → PiP and sync correct.
- [ ] **Step 5:** Wi-Fi off on the phone mid-recording → "Phone disconnected.", file saved, `truncated: true`.
- [ ] **Step 6:** Second Mac (or `nc` to the port) → unauthenticated socket does not block; a second paired Mac gets "Phone is in use by another computer".
- [ ] **Step 7:** Revoke on phone → next arm shows the code again. Clear app data on phone → Mac reports new identity → Forget → pair again.
- [ ] **Step 8:** Screen off 2 min while streaming → continues. Cancel during the pairing prompt → connection closed, phone returns to Advertising.
- [ ] **Step 9:** Hotkey with phone main stored: phone app open → records; app closed → "Phone not found".
- [ ] **Step 10:** Record results; file follow-ups.

### Task 15: Release plumbing + README

- [ ] **Step 1:** `RELEASING.md`: `cd android && ./gradlew assembleRelease` with signing config from env (`CS_PHONE_KEYSTORE`, `CS_PHONE_KEYSTORE_PASSWORD`, `CS_PHONE_KEY_ALIAS`, `CS_PHONE_KEY_PASSWORD`), never committed; attach `CaptureStudioPhone.apk` to the GitHub Release.
- [ ] **Step 2:** `README.md` "Use your Android phone as a camera (Wi-Fi)".
- [ ] **Step 3:** Commit `docs: phone companion release and usage`.
