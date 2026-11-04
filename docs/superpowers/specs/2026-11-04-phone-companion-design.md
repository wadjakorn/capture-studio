# Phone companion: built-in Android camera/mic over Wi-Fi — design

Date: 2026-11-04. Status: draft v2.2 (after two review passes; v2.1: two post-implementation rulings; v2.2: final-review amendments, see Changelog). Depends on
`2026-11-04-phone-camera-and-main-source-design.md` (Part B: `MainSource`,
track roles, camera-main recording).

Changelog: v2.1 (2026-11-04) - Writing rule 5 priming-trim conditions; Security
"Busy handling" 120 s pairing deadline for a socket mid-pairing.
v2.2 (2026-11-04) - Writing rule 3: `mirrored` affects the preview only, never
the file; Security "Not covered" adds first-pairing impersonation by a LAN peer.

## Intent

An Android phone (Samsung Galaxy first) becomes a camera and microphone for
Capture Studio over Wi-Fi with **no third-party app and no adb**. The user
installs our own "Capture Studio Phone" app, opens it, and the phone appears
in the Mac recorder's pickers like any other camera/mic. It can be the main
video, the front camera, and/or the microphone.

Why: the only wired path is Galaxy S26 only and video-only; every wireless
path today needs someone else's app. Owning both ends gives any Galaxy, mic
included, and lets us keep the host-clock sync invariant exactly.

## Goals

- Phone shows up in the Main / Front camera / Microphone pickers within ~2 s
  of opening the phone app on the same Wi-Fi network. Disappears when closed
  cleanly (a crash can leave a ghost entry until the Bonjour TTL expires; the
  Mac then reports "Phone not reachable" at arm).
- First use pairs with a 6-digit code confirmed on the phone; later sessions
  connect silently. Only paired Macs can start the phone's camera.
- 1080p30 H.264 video + AAC audio, ~8 Mbps. Network latency does not affect
  the file: frames are timestamped on the phone and mapped to the Mac host
  clock.
- Recorded `camera.mp4` / `main-camera.mp4` / `mic.m4a` have the same shape
  as today's: H.264 mp4, AAC m4a, `sessionStartHostTime` on the Mac host
  clock, offsets pure arithmetic in Studio. Lip sync within ±1 frame against
  a local mic or the screen track.
- Live preview on the Mac during arm/record, same panel as the local camera.
  **The Mac preview is the monitor; the phone shows status only in v1.**
- Wi-Fi drop or phone app killed mid-recording: track finalizes with
  `truncated: true`, recording still saves, warning shown.
- Phone keeps streaming with screen off (foreground service + wake lock +
  Wi-Fi lock).

## Non-goals

- Bluetooth (no bandwidth, no mic role). USB transport of our protocol.
- Switching camera facing or resolution **while writing** (allowed while
  armed; blocked once recording starts — passthrough writing is bound to one
  SPS/PPS).
- On-phone live preview (v1). CameraX binds one `Preview` per camera; a
  second surface needs a GL fan-out. Revisit after v1.
- Mac → phone control beyond start/stop/keyframe-request/facing/resolution.
- iOS companion. More than one phone at a time. Internet/relay. Play Store
  for v1 (sideloaded APK on GitHub Releases).

## Anti-goals

- Re-encoding on the Mac. Video and audio are written passthrough.
- A Core Media I/O camera extension or virtual audio driver.
- Storing a long-lived secret in plain UserDefaults.
- New Swift package dependencies (Network.framework, Security, CryptoKit,
  CoreMedia, AVFoundation only).

## Constraints

- Mac: CLT toolchain, macOS 15+, Swift 5 mode. `Resources/Info.plist` gains
  `NSLocalNetworkUsageDescription` and `NSBonjourServices`.
- Android: `android/` in this repo. Kotlin 2.0 + Compose (with the
  `org.jetbrains.kotlin.plugin.compose` plugin), Gradle wrapper committed
  (including `gradle-wrapper.jar`), SDK 34 at `~/Library/Android/sdk`,
  Java 17. **minSdk 30** (foreground service types `camera|microphone` exist
  from API 30), targetSdk 34. CameraX 1.3, MediaCodec, NsdManager,
  javax.net.ssl, AndroidKeyStore. No WebRTC, no BouncyCastle.
- Protocol major negotiated in HELLO; mismatched majors refuse with "update
  the other app".
- Keychain under ad-hoc signing: each rebuild changes the code identity, so
  the file keychain may prompt once per rebuild. Fine with the
  `Capture Studio Dev` cert; documented.

## Roles and transport

**Phone = server + advertiser. Mac = browser + client.**

- Phone advertises `_capturestudio._tcp` via NsdManager, TXT `id=<stable
  UUID>`, `name=<Build.MODEL>`, `pv=1`. Port from `ServerSocket(0)`. The
  service is unregistered in `onDestroy`.
- Mac browses with `NWBrowser(.bonjourWithTXTRecord)`; results become
  `PhoneDevice` (id, name, endpoint, pv) in `PhoneBrowser`
  (`@MainActor ObservableObject`).
- **Browser policy** (avoids a Local Network prompt for users who never use a
  phone): the browser starts when the tray popup opens **only if** at least
  one pairing exists, or when the user taps the "Find phones…" row in the
  picker. The hotkey path with a stored `phone:` main starts the browser and
  waits up to 3 s for that id, else fails "Phone not found".
- One `NWConnection` with TLS per recording; control, video and audio share
  it. Closed on stop/cancel/quit.

### Security (plain English)

The phone is the device being accessed, so the phone authenticates the Mac,
and the Mac verifies it is talking to the phone it paired with.

- **Phone identity:** an AndroidKeyStore EC P-256 key (`PURPOSE_SIGN`,
  digests `NONE, SHA256, SHA384, SHA512` — Conscrypt signs pre-hashed TLS
  data with `NONEwithECDSA`, no user authentication required). AndroidKeyStore
  issues a self-signed X.509 certificate for it; the TLS server presents it.
  Fingerprint = SHA-256 of the certificate DER.
- **Mac pins the phone:** Network.framework TLS 1.2+ with a verify block that
  accepts only a leaf whose fingerprint equals the stored one. If a pairing
  exists and the fingerprint differs, the Mac fails with `identityChanged`
  and offers "Forget this phone and pair again" (never silently re-trusts).
  If no pairing exists, the presented fingerprint feeds the pairing code.
- **Pairing uses a commitment so a man-in-the-middle cannot grind the code**
  (a naive `H(fingerprint ‖ macNonce)` lets an attacker who terminates TLS
  brute-force a phone-side nonce until both screens match):
  1. Mac → `PAIR_COMMIT`: `SHA-256(N_M)` where `N_M` is 32 random bytes.
  2. Phone → `PAIR_NONCE`: `N_P`, 32 random bytes.
  3. Mac → `PAIR_REVEAL`: `N_M`. Phone checks `SHA-256(N_M)` equals the
     commitment, else `PAIR_DENIED`.
  4. Both compute `code = u32BE(SHA-256(F_phone ‖ N_M ‖ N_P)[0..<4]) mod
     1_000_000`, zero-padded to 6 digits (unbiased, unlike "first digits").
     The Mac shows "Pair with Galaxy S26? Code 483 921" in a floating pairing
     panel; the phone shows the same code with Allow / Deny. The user confirms
     **on the phone**. Pairing waits up to 120 s and is cancellable from the
     Mac's Cancel.
  5. On Allow the phone generates a 32-byte token, stores `SHA-256(token)`
     with the Mac's name, and sends `PAIR_OK(token)` once. The Mac stores
     `{fingerprint, token}` in the login keychain (`SecItemAdd`, generic
     password, service `dev.wadjakorn.capture-studio.phone`, account = phone
     id).
- **Later connections:** `AUTH(token)` first; phone compares hashes →
  `AUTH_OK` or close. Revocation from the phone's "Paired computers" list.
- **Busy handling:** only an *authenticated* session occupies the phone. A
  second authenticated client gets `ERROR busy`. Unauthenticated sockets are
  dropped after 10 s, except a socket mid-pairing after a valid `PAIR_REVEAL`,
  which instead gets a 120 s pairing deadline, then `PAIR_DENIED` and close.
  TCP keepalive on both sides.
- **Threats covered:** LAN stranger cannot start the camera (no token), cannot
  impersonate the phone (pin), cannot read the stream (TLS), cannot win the
  pairing with better than 1-in-a-million odds (commitment). Not covered: a
  compromised Mac user account, a user who taps Allow without reading, and
  a LAN peer impersonating a not-yet-paired phone during first pairing (the
  Mac accepts PAIR_OK from whichever endpoint it browsed; a Mac-side "codes
  match" confirmation is a planned follow-up).

## Protocol

Framed messages over the TLS stream: `type: UInt8`, `length: UInt32 BE`,
`payload`. Integers big-endian. JSON payloads UTF-8. Max payload 8 MiB.

| Type | Dir | Payload |
|---|---|---|
| `HELLO` (1) | both | JSON `{pv, deviceName, model, caps:[video,audio]}` |
| `AUTH` (2) | Mac→phone | 32-byte token |
| `AUTH_OK` (3) / `AUTH_FAIL` (4) | phone→Mac | none |
| `PAIR_COMMIT` (5) | Mac→phone | 32 bytes `SHA-256(N_M)` |
| `PAIR_NONCE` (6) | phone→Mac | 32 bytes `N_P` |
| `PAIR_REVEAL` (7) | Mac→phone | 32 bytes `N_M` |
| `PAIR_OK` (8) | phone→Mac | 32-byte token (after Allow) |
| `PAIR_DENIED` (9) | phone→Mac | none |
| `CLOCK_PING` (10) | Mac→phone | `u64 macSendHostNs` |
| `CLOCK_PONG` (11) | phone→Mac | `u64 macSendHostNs, u64 phoneRecvNs, u64 phoneSendNs` |
| `START` (12) | Mac→phone | JSON `{video, audio, facing, width, height, fps, bitrate}` |
| `VIDEO_CONFIG` (13) | phone→Mac | `u8 count, then count × (u16 len, NAL bytes)` — raw SPS/PPS NAL units (with NAL header byte, no start code) |
| `VIDEO_FRAME` (14) | phone→Mac | `u64 ptsNs, u8 flags (bit0 keyframe, bit1 mirrored), u16 rotationDeg, AVCC NAL units (4-byte lengths)` |
| `AUDIO_CONFIG` (15) | phone→Mac | AAC AudioSpecificConfig bytes |
| `AUDIO_FRAME` (16) | phone→Mac | `u64 ptsNs, AAC access unit` |
| `KEYFRAME_REQ` (17) | Mac→phone | none (`PARAMETER_KEY_REQUEST_SYNC_FRAME`) |
| `STOP` (18) | Mac→phone | none |
| `ERROR` (19) | both | JSON `{code, message}` then close. Codes: `busy`, `version`, `denied`, `internal` |

Sequence: TLS → HELLO/HELLO → AUTH, or PAIR_COMMIT/NONCE/REVEAL/OK → 20×
CLOCK_PING/PONG → START → VIDEO_CONFIG, AUDIO_CONFIG, frames … →
(KEYFRAME_REQ at `beginWriting`) → STOP → close. Pings continue every 2 s
while streaming for drift logging only.

**Invariants:** video is H.264 **Baseline** profile, no B-frames → DTS == PTS
and PTS strictly increasing from the phone. Frames never contain inline
SPS/PPS (the phone strips NAL types 7/8 from frames; only `VIDEO_CONFIG`
carries them). One `VIDEO_CONFIG` per START.

### Phone clock

All phone timestamps (`CLOCK_PONG`, video PTS, audio PTS) are on
**`SystemClock.elapsedRealtimeNanos()` (BOOTTIME)**. Camera buffers follow
`SENSOR_INFO_TIMESTAMP_SOURCE`: `REALTIME` → already BOOTTIME; `UNKNOWN`
(common on Samsung) → `System.nanoTime()` (MONOTONIC), which diverges from
BOOTTIME by every suspend. The phone reads the characteristic via
`Camera2CameraInfo` and, for `UNKNOWN`, converts with an offset sampled as
the minimum of 5 adjacent `(elapsedRealtimeNanos − nanoTime)` readings taken
at START. Audio PTS come from `AudioRecord.getTimestamp(ts,
TIMEBASE_BOOTTIME)` plus frames written since, never from read-return times.

### Clock mapping (Mac)

`offset = median over the 5 lowest-RTT of 20 samples of
((macSend + macRecv)/2 − (phoneRecv + phoneSend)/2)`. `hostPTS = ptsNs +
offset`. Fixed at `beginWriting`; drift (50 ppm ≈ 180 ms/hour) is logged if
observed and left for a later slewing change. Minimum RTT > 100 ms → warning
"Wi-Fi is slow; audio sync may be off" (recording proceeds).

### Media

- Video: hardware `MediaCodec` `video/avc`, `KEY_PROFILE Baseline`,
  `KEY_MAX_B_FRAMES 0`, 1920×1080 default (CameraX picks the final size via
  `SurfaceRequest.resolution`; the codec is configured inside the
  `SurfaceProvider` callback to that size), 30 fps, 8 Mbps, keyframe
  interval 1 s. Annex-B output converted to AVCC on the phone. Frames are in
  sensor orientation; `rotationDeg` = `SurfaceRequest.TransformationInfo.
  rotationDegrees`, `mirrored` for the front camera.
- Audio: AAC-LC 48 kHz mono 128 kbps from `AudioRecord(VOICE_RECOGNITION)`.
  The MediaCodec AAC encoder priming delay (nominally 2112 samples ≈ 44 ms)
  is removed on the Mac via `kCMSampleBufferAttachmentKey_TrimDurationAtStart`
  on the first access unit; the exact value is measured on hardware in the
  verification task.

## Mac side

### New types (`Sources/CaptureStudio/Recorder/Phone/`)

- `PhoneDevice`, `PhoneDeviceID` (`phone:<id>`, `phone-mic:<id>`).
- `PhoneBrowser`.
- `PhoneFraming` + payload structs (pure). `ClockSync` (pure).
  `PairingCode` (pure, shared vector with Android).
- `PhonePairingStore` (keychain behind a `PairingBackend` protocol).
- `PhoneConnection`: `NWConnection` + pin + message loop; control replies
  via continuations with a 10 s timeout (120 s for `PAIR_OK`), cancellable.
- `MediaPassthrough` (pure helpers): H.264 format description from SPS/PPS
  (`CMVideoFormatDescriptionCreateFromH264ParameterSets`, `nalUnitHeaderLength
  4`), AAC format description from ASC (+ magic cookie), video samples with
  `kCMSampleAttachmentKey_NotSync` on non-keyframes, audio samples via
  `CMAudioSampleBufferCreateReadyWithPacketDescriptions`, rotation →
  `CGAffineTransform` (rotation ‖ translation), `PTSGate`, `PTSFloor`.
- `PhoneStreamRecorder: CameraSourceRecorder`.

### Writing rules (`PhoneStreamRecorder`)

1. `warmUp()`: connect → authenticate/pair → clock sync → START. Preview
   frames flow immediately.
2. `beginWriting()` does **not** create the writer. It records
   `beginHostNs = now`, sets `shouldWrite`, and sends `KEYFRAME_REQ`.
3. On the connection queue, the first video frame that (a) has `hostPTS ≥
   beginHostNs` (frames captured before the user pressed Record are dropped
   even though they arrive later — otherwise Studio's `max(0, offset)` clamp
   bakes in the network latency) and (b) is a keyframe: create the
   `AVAssetWriter` + passthrough input, set `input.transform` from this
   frame's `rotationDeg` only; `mirrored` affects the preview, never the file
   (transform must precede `startWriting`),
   `startWriting`, `startSession(atSourceTime: hostPTS)`,
   `sessionStartHostTime = hostPTS.seconds`. Rotation changes afterwards are
   ignored and warned.
4. Never drop a frame because `isReadyForMoreMediaData` is false (a dropped
   P-frame corrupts the GOP): enqueue into a bounded buffer (2 s) drained by
   `requestMediaDataWhenReady`; overflow → `truncated` + warning.
5. Audio (when riding this recorder) has its own anchor from the first
   accepted access unit (`hostPTS ≥ beginHostNs`), like `CameraRecorder`'s
   `audioStartHostTime`. The priming trim is attached only when that first
   accepted AU is also the first AU the phone sent since `START`; a mid-stream
   first AU gets no trim. When applied, the trim is capped per AU to the AU's
   duration and the remainder is carried to the following AUs.
6. `writtenPixelSize` is **post-rotation** (swap for 90/270) so
   `DisplayInfo.synthetic` describes what the viewer sees.
7. Preview: a separate `CMSampleBuffer` copy per frame with
   `kCMSampleAttachmentKey_DisplayImmediately` enqueued on an
   `AVSampleBufferDisplayLayer` (the layer has no control timebase; mapped
   host PTS are already in the past). Rotation/mirroring as a layer
   transform. `.failed` status → `flush()` and recreate.
8. Non-mic warnings (slow Wi-Fi) go to `warmUpWarnings: [String]`, **not**
   `micWarning` (a `micWarning` triggers `arm()`'s standalone-mic fallback).
9. Connection loss → `markTruncated`, `onDeviceLost("Phone disconnected.")`,
   writers finalize on stop.

### Recorder abstraction

```swift
enum PreviewSurface { case captureSession(AVCaptureSession), displayLayer(AVSampleBufferDisplayLayer) }
protocol CameraSourceRecorder: AnyObject {
    var previewSurface: PreviewSurface? { get }          // nil for the mic-only phone recorder
    var sessionStartHostTime: Double? { get }
    var truncated: Bool { get }
    var micWarning: String? { get }
    var warmUpWarnings: [String] { get }
    var writtenPixelSize: CGSize? { get }
    var onDeviceLost: (@Sendable (String) -> Void)? { get set }   // same type as CameraRecorder (Part B)
    func warmUp() async throws
    func beginWriting() throws
    func stop() async throws -> CameraSourceResult               // camera optional
    func discard() async
}
struct CameraSourceResult { var camera: TrackInfo?; var mic: TrackInfo? }
```

`CameraRecorder` adopts it (`previewSurface = .captureSession(session)`,
mirror stays on `AVCaptureConnection.isVideoMirrored`). `CameraPreviewPanel`
takes a `PreviewSurface`; for `.displayLayer` the mirror toggle transforms the
display sublayer only.

`RecordingSession`:
- `cameraRecorder`, `mainCameraRecorder`: `(any CameraSourceRecorder)?`.
- New `phoneMicRecorder: PhoneStreamRecorder?` (video false) for a phone mic
  with non-phone video; handled at every site `micRecorder` is.
- New `pendingRecorder: (any CameraSourceRecorder)?` holding the recorder
  whose `warmUp()` is in flight, so `tearDownArmed` (Cancel during pairing)
  can `discard()` it instead of leaving the phone busy.
- **Candidate camera ids come from one helper**
  `availableCameraIDs() = DeviceDiscovery.cameras().map(\.uniqueID) +
  PhoneBrowser.shared.phones.map(PhoneDeviceID.camera)`, used by `arm`,
  `toggleFromHotkey`, and `RecorderSelection.frontCameraIDs`. Part B's
  resolver must take ids from it, otherwise a phone main fails as "camera no
  longer available".
- Factory `makeCameraSource(id:…)` branches on the `phone:` prefix **before**
  the `AVCaptureDevice` lookup.
- `tearDownForQuit` also closes phone connections.

Phone mic rules (`RecorderSelection.phonePlan`):
- mic `phone-mic:X` + video `phone:X` (main or overlay) → rides that recorder
  (`audio: true`).
- mic `phone-mic:X` + no phone video → `phoneMicRecorder`.
- phone video + local mic → phone recorder `audio: false`; the local mic goes
  through `warmUpStandaloneMic` explicitly (the phone recorder cannot host an
  `AVCaptureDevice`).
- video `phone:X` + mic `phone-mic:Y` (Y ≠ X) → rejected in the picker;
  session warns "Use one phone for both video and microphone".

### Pickers

Replace the `[(kind, [AVCaptureDevice])]` grouping with a row model
`PickerRow { id, name, kind: DeviceKind, enabled: Bool, hint: String? }` built
from local devices and `PhoneBrowser.phones`. "Phone (Wi-Fi)" group: phones
(disabled with "Update required" on `pv` mismatch), or a "Find phones…" row
when the browser is idle, or "Open Capture Studio Phone on your Android
device" when browsing and empty.

### Pairing UI

`RecordingSession` publishes `pairing: PairingPrompt?` (`phoneName`, `code`).
A floating `PairingPanel` (NSPanel, same style as the HUD) shows "Confirm
483 921 on Galaxy S26" with Cancel while non-nil; arm stays in `.arming`
until `PAIR_OK`/`PAIR_DENIED`/timeout/Cancel.

### Studio

`makeComposition` (Part B Task 8) must honor the main and overlay tracks'
`preferredTransform`: apply it in the layer instructions and use the
transformed natural size for `renderSize`/PiP math. Today it ignores the
transform entirely, so a portrait phone would render sideways. Thumbnails
already apply it (`appliesPreferredTrackTransform`).

## Android side (`android/`)

Single module `app`, package `dev.wadjakorn.capturestudio.phone`.

- `MainActivity` (Compose): onboarding (camera, mic, notifications
  permissions; request battery-optimization exemption — Samsung "put unused
  apps to sleep" kills foreground services otherwise), status card
  (Advertising / Connected to "MacBook Pro" / Streaming), facing toggle +
  resolution (applied at next START; disabled while streaming), keep-screen-on
  switch, pairing dialog (code "483 921", Allow/Deny), "Paired computers" with
  Revoke. No camera preview in v1.
- `StreamService`: foreground service type `camera|microphone`, **started from
  the activity while visible** (Android 11+ denies camera/mic to services
  started from the background). Owns a `LifecycleRegistry` (CameraX cannot
  bind to the Activity: screen-off → `onStop` closes the camera), partial wake
  lock and `WifiManager.WifiLock(WIFI_MODE_FULL_LOW_LATENCY)` while streaming,
  notification with Stop. Unregisters NSD and releases everything in
  `onDestroy`.
- `Advertiser` (NsdManager), `TlsServer` (`SSLServerSocket` over the
  AndroidKeyStore identity via `KeyManagerFactory`), `MessageCodec`
  (framing), `Session` (state machine, busy rules, 10 s unauth timeout),
  `PairingStore` (SharedPreferences, token hashes + names only),
  `PhoneClock` (BOOTTIME + MONOTONIC conversion), `VideoPipeline`
  (CameraX `Preview` → codec input surface created in the `SurfaceProvider`
  callback; Annex-B → AVCC; strip 7/8; `TransformationInfo` rotation; release
  order: surface-request result callback before `codec.release()`),
  `AudioPipeline` (`AudioRecord` → AAC; BOOTTIME timestamps).
- JUnit tests: framing round-trip + partial tail + header bytes, pairing code
  vector (shared literal with Swift), `CLOCK_PONG` layout, Annex-B → AVCC
  conversion, SPS/PPS stripping.

## Compatibility and ordering

Part B first. Part B's plan gets two amendments from this design: (1)
`makeComposition` honors `preferredTransform`; (2) camera candidate ids come
from `availableCameraIDs()`. Part A's third-party-app help copy is dropped.

## Test hardware

A Galaxy on hand (model and One UI version to be recorded in the plan's
verification task). Exynos vs Snapdragon encoders differ in inline SPS/PPS
and timestamp behavior; both paths are handled by the invariants above, but
only the model on hand gets verified.

## Deliverables

1. Mac: discovery, pairing, streaming, recording, preview, Studio transform.
2. Android APK via `android/gradlew assembleRelease`, signed with a local
   keystore, attached to GitHub Releases.
3. `README.md` section "Use your Android phone as a camera".

## Calls made by the author (not confirmed by the user)

- Phone is the TLS server; Mac authenticates with a pairing token; the user
  confirms on the phone.
- Commitment-based pairing code (one extra round trip) instead of a QR code.
- No on-phone preview in v1; no facing/resolution switch while writing.
- Passthrough writing; lazy writer creation at the first keyframe after
  Record; pre-Record frames dropped.
- Fixed clock offset per recording (drift logged, not slewed).
- Browser starts lazily (pairing exists, or "Find phones…" tapped).
- Baseline profile only. minSdk 30. Sideloaded APK.
