# Permission Onboarding & Capture-Issue Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** First-run permission onboarding, live permission status, visible (never silent) pre-record permission failures, and immediate toasts for mid-session device/capture loss.

**Architecture:** A pure permission model (`PermissionKind`/`PermissionStatus`) + an observable `PermissionCenter` feed every surface (popup, onboarding window, Dashboard banner) and the session's start path, which consults pure `PermissionPreflight` rules. Loss detection plugs into the existing `RecordingSession.warnings` / `.failed` pipeline; one `SessionIssueNotifier` turns new warnings and failures into a non-activating toast.

**Tech Stack:** Swift 6 toolchain with `.swiftLanguageMode(.v5)` on both targets (`Package.swift:30,39`), SwiftUI + AppKit, AVFoundation, ScreenCaptureKit, Network (`NWBrowser`), Combine, swift-testing 0.12.0.

**Spec:** `docs/superpowers/specs/2026-11-27-permission-onboarding-design.md`

**Scrutiny:** an independent reviewer checked this plan against the code on 2026-11-27; its fixes are folded in (see "Scrutiny ledger" at the end).

## Global Constraints

- Target macOS 15+. Language mode is Swift 5 (strict concurrency is **not** compiler-enforced), so write isolation-correct code by hand: main-actor UI types are `@MainActor`; pure helpers stay non-isolated (`nonisolated static` when they live on a View or a `@MainActor` type, like `DashboardView.trashMessage` at `DashboardView.swift:321`) so tests call them without `@MainActor`.
- Every `RecordingSession` failure goes through one helper `fail(_ message: String, permission: PermissionKind? = nil)` (Task 4), which assigns `failurePermission` **before** `state = .failed(message)` — the notifier reads it when `state` publishes.
- Must build/test under both toolchains: `swift test` and `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test`. No new package dependencies, no `#Preview`, do not bump swift-testing / KeyboardShortcuts / Sparkle pins.
- No entitlement or Info.plist change: camera/mic entitlements and all usage strings (`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices`) already exist.
- New chrome windows/panels (toast, onboarding window) must **not** call `CaptureContentWindows.shared.register` — they must stay out of `screen.mp4`.
- Architecture invariants in `CLAUDE.md` stay intact (cursor not baked in, host-clock sync, CameraRecorder master-clock fix, preview/record split).
- UI copy in English, exactly as written in this plan.
- Tests: swift-testing (`import Testing`, `@testable import CaptureStudio`, `@Test`, `#expect`). Pure helpers only; capture/UI glue is not unit-tested.
- Work on branch `feat/permission-onboarding` from `main`. Commit steps require the user's explicit OK (CLAUDE.md: never commit or push without confirmation); without it, stage only. Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Never push / force-push.
- `@Published` sinks fire in `willSet`: never re-read the publishing object's property inside a sink. Use the delivered value, or `.receive(on: DispatchQueue.main)` before reading (never `MainActor.assumeIsolated` to skip the hop).

## Review Focus

1. User grants Screen Recording in System Settings while the app runs, but `CGPreflightScreenCaptureAccess()` stays false until relaunch → UI must offer **Relaunch**, not an "Allow" button that does nothing. (Task 1 `screenStatusMapping`; Task 2 `fix(.screenRecording)` opens onboarding + Settings; Task 6 Relaunch button.)
2. Hotkey pressed with Screen Recording off — including a brand-new user whose popup never saved a display (`AppSettings.lastMainSource == nil`) → a visible "Can't start recording" toast with a Fix button, no bundle created, no silent no-op. (Task 3 `displayWithoutScreenBlocks`; Task 5 `failureTitles`; Task 5 Step 4 `main == nil` branch.)
3. Screen Recording toggled off mid-recording → partial recording saved, toast titled "Recording stopped early" (not "Can't start recording"), message names the permission, Fix leads to Screen Recording — even if ScreenCaptureKit reports a generic code. (Task 4 `revokedGrantWinsOverCode`; Task 4 Step 4 `completeSave` goes `.finishing → .failed` directly.)
4. User clicks "Stop" in the macOS screen-sharing menu-bar item → treated as a normal stop (Studio/toast as usual), no failure. (Task 4 `userStopIsNormalStop`.)
5. Upgrader with every permission already granted, or a login-item launch → never sees the onboarding window. (Task 6 `onboardingSkippedWhenAllGranted`, `onboardingSkippedForLoginItem`.)

---

### Task 1: Permission model + settings flags

**Files:**
- Modify: `Sources/CaptureStudio/Recorder/Permissions.swift`
- Modify: `Sources/CaptureStudio/App/AppSettings.swift`
- Test: `Tests/CaptureStudioTests/PermissionModelTests.swift`

**Interfaces:**
- Produces:
  - `enum PermissionKind: String, CaseIterable, Sendable { case screenRecording, microphone, camera, localNetwork }` with `var title: String` ("Screen Recording", "Microphone", "Camera", "Local Network") and `var settingsURL: URL`.
  - `enum PermissionStatus: Equatable, Sendable { case granted, notDetermined, denied, unknown }` with
    `static func fromAV(_ status: AVAuthorizationStatus) -> PermissionStatus`,
    `static func screen(preflight: Bool, requestedBefore: Bool) -> PermissionStatus`,
    `static func localNetwork(policyDenied: Bool, hasSeenPhone: Bool) -> PermissionStatus`.
  - `Permissions.openSettings(_ kind: PermissionKind)` (existing `openScreenRecordingSettings()` becomes `openSettings(.screenRecording)`; keep the other existing `Permissions` functions unchanged).
  - `AppSettings.screenRecordingRequested: Bool` (key `"screenRecordingRequested"`, default `false`), `AppSettings.permissionOnboardingDone: Bool` (key `"permissionOnboardingDone"`, default `false`).

- [ ] **Step 1: Write the failing tests** in `PermissionModelTests.swift`:

```swift
import Testing
import AVFoundation
@testable import CaptureStudio

@Test func avStatusMapping() {
    #expect(PermissionStatus.fromAV(.authorized) == .granted)
    #expect(PermissionStatus.fromAV(.notDetermined) == .notDetermined)
    #expect(PermissionStatus.fromAV(.denied) == .denied)
    #expect(PermissionStatus.fromAV(.restricted) == .denied)
}

@Test func screenStatusMapping() {
    #expect(PermissionStatus.screen(preflight: true, requestedBefore: false) == .granted)
    #expect(PermissionStatus.screen(preflight: true, requestedBefore: true) == .granted)
    #expect(PermissionStatus.screen(preflight: false, requestedBefore: false) == .notDetermined)
    // Asked before and still not granted: denied, or granted-pending-relaunch.
    #expect(PermissionStatus.screen(preflight: false, requestedBefore: true) == .denied)
}

@Test func localNetworkStatusMapping() {
    #expect(PermissionStatus.localNetwork(policyDenied: true, hasSeenPhone: true) == .denied)
    #expect(PermissionStatus.localNetwork(policyDenied: false, hasSeenPhone: true) == .granted)
    #expect(PermissionStatus.localNetwork(policyDenied: false, hasSeenPhone: false) == .unknown)
}

@Test func settingsURLsTargetPrivacyPanes() {
    let base = "x-apple.systempreferences:com.apple.preference.security?"
    #expect(PermissionKind.screenRecording.settingsURL.absoluteString == base + "Privacy_ScreenCapture")
    #expect(PermissionKind.microphone.settingsURL.absoluteString == base + "Privacy_Microphone")
    #expect(PermissionKind.camera.settingsURL.absoluteString == base + "Privacy_Camera")
    #expect(PermissionKind.localNetwork.settingsURL.absoluteString == base + "Privacy_LocalNetwork")
}
```

- [ ] **Step 2: Run** `swift test --filter PermissionModelTests` → FAIL (types not defined).
- [ ] **Step 3: Implement** the types above in `Permissions.swift` and the two `AppSettings` properties (same getter/setter style as `recordSystemAudio`). `fromAV` uses `@unknown default: .denied`.
- [ ] **Step 4: Run** `swift test --filter PermissionModelTests` → PASS; `swift build` → succeeds.
- [ ] **Step 5: Commit** (with user OK) — `feat(permissions): permission kind/status model`.

---

### Task 2: Local Network detection + `PermissionCenter`

**Files:**
- Modify: `Sources/CaptureStudio/Recorder/Phone/PhoneBrowser.swift`
- Create: `Sources/CaptureStudio/App/PermissionCenter.swift`
- Test: `Tests/CaptureStudioTests/PhoneBrowserPolicyTests.swift`

**Interfaces:**
- Consumes: Task 1 types, `Permissions`, `AppSettings.screenRecordingRequested`.
- Produces:
  - `PhoneBrowser`: `@Published private(set) var localNetworkDenied = false`, `@Published private(set) var hasSeenPhone = false`, `nonisolated static let policyDeniedCode: DNSServiceErrorType = -65570` (kDNSServiceErr_PolicyDenied), `nonisolated static func isLocalNetworkDenied(_ error: NWError) -> Bool`.
  - `@MainActor final class PermissionCenter: ObservableObject` with `static let shared`, `@Published private(set) var statuses: [PermissionKind: PermissionStatus]`, `func status(_ kind: PermissionKind) -> PermissionStatus` (missing key → `.unknown`), `func isGranted(_ kind: PermissionKind) -> Bool`, `func refresh()`, `func request(_ kind: PermissionKind) async`, `func fix(_ kind: PermissionKind) async`, `func openSettings(_ kind: PermissionKind)`.

- [ ] **Step 1: Write the failing tests** in `PhoneBrowserPolicyTests.swift`:

```swift
import Testing
import Network
@testable import CaptureStudio

@Test func policyDeniedDNSErrorIsLocalNetworkDenial() {
    #expect(PhoneBrowser.isLocalNetworkDenied(.dns(-65570)))
}

@Test func otherErrorsAreNotLocalNetworkDenial() {
    #expect(!PhoneBrowser.isLocalNetworkDenied(.dns(-65537)))       // kDNSServiceErr_Unknown
    #expect(!PhoneBrowser.isLocalNetworkDenied(.posix(.ECONNREFUSED)))
}
```

- [ ] **Step 2: Run** `swift test --filter PhoneBrowserPolicyTests` → FAIL.
- [ ] **Step 3: Implement in `PhoneBrowser`:** `stateUpdateHandler` handles `.waiting(let e)`: log it; if `isLocalNetworkDenied(e)` set `localNetworkDenied = true`. `.ready`: `isBrowsing = true; localNetworkDenied = false`. `.failed(let e)`: if denied set the flag, then `reset()` as today. When results produce a non-empty `phones`, set `hasSeenPhone = true` and `localNetworkDenied = false`. `reset()` must **not** clear `localNetworkDenied` / `hasSeenPhone` (sticky across stop/start).
- [ ] **Step 4: Implement `PermissionCenter`:**
  - `init()` → `refresh()`; observe `NSApplication.didBecomeActiveNotification` → `refresh()`; Combine-sink `PhoneBrowser.shared.$localNetworkDenied` and `$hasSeenPhone` through `.receive(on: DispatchQueue.main)` → `refresh()` (the hop lets the new value land before `refresh()` reads it; see Global Constraints). Store cancellables.
  - `refresh()`: if `Permissions.screenRecordingGranted()` is true, set `AppSettings.screenRecordingRequested = true` first (an upgrader who granted before the flag existed and later revokes must read `.denied`, not `.notDetermined`). Then screen = `.screen(preflight: Permissions.screenRecordingGranted(), requestedBefore: AppSettings.screenRecordingRequested)`; camera/mic = `.fromAV(AVCaptureDevice.authorizationStatus(for: .video/.audio))`; localNetwork = `.localNetwork(policyDenied:hasSeenPhone:)` from `PhoneBrowser.shared`. Assign `statuses` only if the dictionary changed.
  - `request(.screenRecording)`: set `AppSettings.screenRecordingRequested = true`, call `Permissions.requestScreenRecording()`, `refresh()`. `.camera/.microphone`: `_ = await AVCaptureDevice.requestAccess(for:)`, `refresh()`. `.localNetwork`: `PhoneBrowser.shared.start()` (the OS prompts on first browse), `refresh()`.
  - `fix(kind)`: `.notDetermined`/`.unknown` → `request(kind)`; `.denied` → `openSettings(kind)`; `.granted` → nothing. (Task 6 extends the `.screenRecording` + `.denied` case to also show the onboarding window, which carries Relaunch.)
  - Known, accepted gap: a user who *denied* Screen Recording through the old popup "Request" button reads `.notDetermined`; their first "Allow" is a silent `CGRequestScreenCaptureAccess()` no-op that sets the flag, and the row then turns into "Open Settings".
  - `openSettings(kind)` → `Permissions.openSettings(kind)`.
- [ ] **Step 5: Run** `swift test --filter PhoneBrowserPolicyTests` → PASS; `swift build` → succeeds.
- [ ] **Step 6: Commit** (with user OK) — `feat(permissions): live permission center + local network denial detection`.

---

### Task 3: Pre-record permission rules

**Files:**
- Create: `Sources/CaptureStudio/Recorder/PermissionPreflight.swift`
- Test: `Tests/CaptureStudioTests/PermissionPreflightTests.swift`

**Interfaces:**
- Consumes: Task 1 types; existing `MainSource` (`isCamera`, `cameraID`), `RecorderSelection.needsScreenPermission(for:)`, `PhoneDeviceID.phoneID(fromCamera:)`, `PhoneDeviceID.phoneID(fromMic:)`.
- Produces:
  - `struct PermissionIssue: Equatable, Sendable { let kind: PermissionKind; let blocking: Bool; let message: String }`
  - `enum PermissionPreflight` with message constants (exact copy):
    - `screenOff = "Screen Recording access is off. Allow it in System Settings to record your screen."`
    - `cameraMainOff = "Camera access is off. Allow it in System Settings to record your camera."`
    - `cameraOverlayOff = "Camera access is off — this recording won't include your camera."`
    - `micOff = "Microphone access is off — this recording won't include your microphone."`
    - `phoneMainOff = "Local Network access is off. Allow it in System Settings to use your phone."`
    - `phoneOptionalOff = "Local Network access is off — your phone camera or microphone can't connect."`
  - `static func issues(main: MainSource, cameraID: String?, micID: String?, status: (PermissionKind) -> PermissionStatus) -> [PermissionIssue]`
  - `static func kind(forMessage message: String) -> PermissionKind?` (maps exactly the six constants; anything else → nil).

Rules (output: blocking issues first, then non-blocking; within each group order screen, camera, microphone, localNetwork):
1. `needsScreenPermission(for: main)` and screen ≠ `.granted` (includes `.notDetermined`) → blocking `screenOff`.
2. Main is a local camera (`main.cameraID` non-nil, not a phone id) and camera == `.denied` → blocking `cameraMainOff`.
3. Otherwise, overlay `cameraID` is a local camera and camera == `.denied` → non-blocking `cameraOverlayOff`.
4. `micID` is a local mic (not a phone mic id) and mic == `.denied` → non-blocking `micOff`.
5. localNetwork == `.denied`: main is a phone camera → blocking `phoneMainOff`; else overlay or mic is a phone source → one non-blocking `phoneOptionalOff`.
6. `.notDetermined` camera/mic and `.unknown` local network are never issues (the start path prompts).

- [ ] **Step 1: Write the failing tests** in `PermissionPreflightTests.swift`:

```swift
import Testing
@testable import CaptureStudio

private func all(_ s: PermissionStatus) -> (PermissionKind) -> PermissionStatus { { _ in s } }
private func only(_ k: PermissionKind, _ s: PermissionStatus) -> (PermissionKind) -> PermissionStatus {
    { $0 == k ? s : .granted }
}
private typealias P = PermissionPreflight

@Test func allGrantedHasNoIssues() {
    #expect(P.issues(main: .display(1), cameraID: "cam", micID: "mic", status: all(.granted)).isEmpty)
}
@Test func displayWithoutScreenBlocks() {
    #expect(P.issues(main: .display(1), cameraID: nil, micID: nil, status: only(.screenRecording, .denied))
            == [PermissionIssue(kind: .screenRecording, blocking: true, message: P.screenOff)])
}
@Test func screenNotDeterminedAlsoBlocks() {
    #expect(P.issues(main: .display(1), cameraID: nil, micID: nil, status: only(.screenRecording, .notDetermined))
            .first?.blocking == true)
}
@Test func cameraMainNeedsNoScreen() {
    #expect(P.issues(main: .camera(uniqueID: "cam"), cameraID: nil, micID: nil,
                     status: only(.screenRecording, .denied)).isEmpty)
}
@Test func deniedMainCameraBlocks() {
    #expect(P.issues(main: .camera(uniqueID: "cam"), cameraID: nil, micID: nil, status: only(.camera, .denied))
            == [PermissionIssue(kind: .camera, blocking: true, message: P.cameraMainOff)])
}
@Test func deniedOverlayCameraWarns() {
    #expect(P.issues(main: .display(1), cameraID: "cam", micID: nil, status: only(.camera, .denied))
            == [PermissionIssue(kind: .camera, blocking: false, message: P.cameraOverlayOff)])
}
@Test func undeterminedCameraIsNotAnIssue() {
    #expect(P.issues(main: .display(1), cameraID: "cam", micID: nil, status: only(.camera, .notDetermined)).isEmpty)
}
@Test func deniedMicWarns() {
    #expect(P.issues(main: .display(1), cameraID: nil, micID: "mic", status: only(.microphone, .denied))
            == [PermissionIssue(kind: .microphone, blocking: false, message: P.micOff)])
}
@Test func phoneMicIgnoresMacMicPermission() {
    #expect(P.issues(main: .display(1), cameraID: nil, micID: "phone-mic:A", status: only(.microphone, .denied)).isEmpty)
}
@Test func phoneMainWithoutLocalNetworkBlocks() {
    #expect(P.issues(main: .camera(uniqueID: "phone:A"), cameraID: nil, micID: nil, status: only(.localNetwork, .denied))
            == [PermissionIssue(kind: .localNetwork, blocking: true, message: P.phoneMainOff)])
}
@Test func phoneOverlayWithoutLocalNetworkWarnsOnce() {
    #expect(P.issues(main: .display(1), cameraID: "phone:A", micID: "phone-mic:A", status: only(.localNetwork, .denied))
            == [PermissionIssue(kind: .localNetwork, blocking: false, message: P.phoneOptionalOff)])
}
@Test func unknownLocalNetworkIsNotAnIssue() {
    #expect(P.issues(main: .camera(uniqueID: "phone:A"), cameraID: nil, micID: nil, status: only(.localNetwork, .unknown)).isEmpty)
}
@Test func blockingIssuesComeFirst() {
    let status: (PermissionKind) -> PermissionStatus = { $0 == .localNetwork ? .granted : .denied }
    let issues = P.issues(main: .display(1), cameraID: "cam", micID: "mic", status: status)
    #expect(issues.map(\.kind) == [.screenRecording, .camera, .microphone])
    #expect(issues.map(\.blocking) == [true, false, false])
}
@Test func messageMapsBackToKind() {
    #expect(P.kind(forMessage: P.micOff) == .microphone)
    #expect(P.kind(forMessage: P.phoneMainOff) == .localNetwork)
    #expect(P.kind(forMessage: "Phone disconnected.") == nil)
}
```

- [ ] **Step 2: Run** `swift test --filter PermissionPreflightTests` → FAIL.
- [ ] **Step 3: Implement** `PermissionPreflight.swift` per the rules.
- [ ] **Step 4: Run** `swift test --filter PermissionPreflightTests` → PASS.
- [ ] **Step 5: Commit** (with user OK) — `feat(permissions): pre-record permission rules`.

---

### Task 4: Capture-loss detection (mic unplug, screen stream stop)

**Files:**
- Modify: `Sources/CaptureStudio/Recorder/MicRecorder.swift`
- Create: `Sources/CaptureStudio/Recorder/ScreenStreamIssue.swift`
- Modify: `Sources/CaptureStudio/Recorder/RecordingSession.swift` (every `state = .failed(` site — 16 today; `warmUpStandaloneMic` ~1463; both `screen.onStreamError` closures ~241 and ~845; screen start failure in `beginRecording` ~914-918; `completeSave` ~1395-1415)
- Test: `Tests/CaptureStudioTests/ScreenStreamIssueTests.swift`

**Interfaces:**
- Consumes: Task 1 `PermissionKind`, Task 3 `PermissionPreflight.screenOff`.
- Produces:
  - `MicRecorder.onDeviceLost: (@Sendable (String) -> Void)?` — reported once per recorder with `"Microphone disconnected."` or `"Microphone error: <description or unknown>"`.
  - `enum ScreenStreamIssue: Equatable, Sendable { case userStopped, permissionRevoked, displayLost, systemStopped, other(String) }` with `static func classify(_ error: Error, screenAccessGranted: Bool) -> ScreenStreamIssue`, `var savedMessage: String`, `var permission: PermissionKind?` (`.screenRecording` for `.permissionRevoked`, else nil).
  - `struct ScreenStreamFailure: LocalizedError { let issue: ScreenStreamIssue }` (`errorDescription` = `issue.savedMessage`).
  - `RecordingSession.failurePermission: PermissionKind?` — `@Published private(set)`, nil by default.
  - `private func fail(_ message: String, permission: PermissionKind? = nil)` on `RecordingSession`: `failurePermission = permission; state = .failed(message)`. After this task no other code assigns `.failed` directly (Task 5 uses `fail` too).

Classification order: SCStream `.userStopped` → `.userStopped` (regardless of grant); else `!screenAccessGranted` → `.permissionRevoked`; else for `SCStreamErrorDomain` codes: `.userDeclined`, `.missingEntitlements` → `.permissionRevoked`; `.noDisplayList`, `.noCaptureSource` → `.displayLost`; `.systemStoppedStream`, `.failedApplicationConnectionInterrupted` → `.systemStopped`; anything else → `.other(error.localizedDescription)`.

`savedMessage` (exact copy):
- `.permissionRevoked`: `"Screen Recording access was turned off. The recording was saved up to that point."`
- `.displayLost`: `"The display was disconnected. The recording was saved up to that point."`
- `.systemStopped`: `"macOS stopped the screen capture. The recording was saved up to that point."`
- `.other(d)`: `"Recording saved, but capture stopped early: \(d)"` (today's text)
- `.userStopped`: `"Screen sharing was stopped."` (never shown; userStopped is a normal stop)

- [ ] **Step 1: Write the failing tests** in `ScreenStreamIssueTests.swift`:

```swift
import Testing
import Foundation
import ScreenCaptureKit
@testable import CaptureStudio

private func sc(_ code: SCStreamError.Code) -> NSError {
    NSError(domain: SCStreamErrorDomain, code: code.rawValue)
}

@Test func userStopIsNormalStop() {
    #expect(ScreenStreamIssue.classify(sc(.userStopped), screenAccessGranted: true) == .userStopped)
    #expect(ScreenStreamIssue.classify(sc(.userStopped), screenAccessGranted: false) == .userStopped)
}
@Test func revokedGrantWinsOverCode() {
    #expect(ScreenStreamIssue.classify(sc(.noDisplayList), screenAccessGranted: false) == .permissionRevoked)
    #expect(ScreenStreamIssue.classify(NSError(domain: "x", code: 1), screenAccessGranted: false) == .permissionRevoked)
}
@Test func declinedIsPermission() {
    let issue = ScreenStreamIssue.classify(sc(.userDeclined), screenAccessGranted: true)
    #expect(issue == .permissionRevoked)
    #expect(issue.permission == .screenRecording)
}
@Test func displayGone() {
    #expect(ScreenStreamIssue.classify(sc(.noDisplayList), screenAccessGranted: true) == .displayLost)
    #expect(ScreenStreamIssue.classify(sc(.noCaptureSource), screenAccessGranted: true) == .displayLost)
}
@Test func systemStop() {
    #expect(ScreenStreamIssue.classify(sc(.systemStoppedStream), screenAccessGranted: true) == .systemStopped)
}
@Test func unknownErrorKeepsDescription() {
    let e = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    let issue = ScreenStreamIssue.classify(e, screenAccessGranted: true)
    #expect(issue == .other("boom"))
    #expect(issue.savedMessage == "Recording saved, but capture stopped early: boom")
    #expect(issue.permission == nil)
}
@Test func savedMessages() {
    #expect(ScreenStreamIssue.permissionRevoked.savedMessage
            == "Screen Recording access was turned off. The recording was saved up to that point.")
    #expect(ScreenStreamIssue.displayLost.savedMessage
            == "The display was disconnected. The recording was saved up to that point.")
}
```

- [ ] **Step 2: Run** `swift test --filter ScreenStreamIssueTests` → FAIL.
- [ ] **Step 3: Implement `ScreenStreamIssue.swift`** per the order above (switch on `SCStreamError.Code(rawValue:)` when `(error as NSError).domain == SCStreamErrorDomain`).
- [ ] **Step 4: Wire the screen path in `RecordingSession`:**
  - Add `failurePermission` and `fail(_:permission:)`; replace every `state = .failed(x)` with `fail(x)` (check with `rtk proxy grep -n "state = .failed" Sources/CaptureStudio/Recorder/RecordingSession.swift` → only the line inside `fail`). `arm()` and `resetFailure()` reset `failurePermission = nil`.
  - Both `screen.onStreamError` closures: classify with `Permissions.screenRecordingGranted()`; `.userStopped` → `await self?.stop()`; otherwise `await self?.stop(streamError: ScreenStreamFailure(issue: issue))`.
  - `completeSave`: today it sets `state = .idle` (~1403) and *afterwards* `.failed` (~1412), so a listener would see `.idle → .failed`. Decide the final state once, before `PostRecordingAction`: `streamError` is a `ScreenStreamFailure` → `fail(failure.issue.savedMessage, permission: failure.issue.permission)`; any other `streamError` (e.g. `MainCameraLostError`) → `fail(<today's text>)`; nil → `state = .idle`. The session must go `.finishing → .failed` with no `.idle` in between. `PostRecordingAction` (open Studio / saved toast) runs unchanged after it.
  - Screen start failure in `beginRecording` (~914-918, `.preparing`): classify the thrown error; `.permissionRevoked` → `fail(PermissionPreflight.screenOff, permission: .screenRecording)` (Task 3 constant); anything else keeps `fail(error.localizedDescription)`. (Task 3 lands before this task, so the constant exists.)
- [ ] **Step 5: Implement mic loss in `MicRecorder`:** after `startRunning` in `warmUp()`, register `AVCaptureDevice.wasDisconnectedNotification` (object nil; act only when the device's `uniqueID == device.uniqueID`) and `AVCaptureSession.runtimeErrorNotification` (object `session`), mirroring `CameraRecorder.deviceWasDisconnected` / `sessionRuntimeError`. Handler: on `queue`, set `truncated = true` and a private `lossReported` latch; call `onDeviceLost` only the first time. `stop()` and `discard()` remove the observers first.
- [ ] **Step 6: Wire it:** in `warmUpStandaloneMic`, before `warmUp()`, set `recorder.onDeviceLost = { [weak self] msg in Task { @MainActor in self?.warnings.append(msg) } }` (same shape as the camera wiring at ~271).
- [ ] **Step 7: Run** `swift test` → all PASS; `swift build` → succeeds.
- [ ] **Step 8: Commit** (with user OK) — `feat(recorder): report mic loss and classify screen-capture stops`.

---

### Task 5: Visible start failures + issue toasts

**Files:**
- Modify: `Sources/CaptureStudio/Recorder/RecordingSession.swift` (`init` ~78, `arm` ~189-201, `toggleFromHotkey`/`waitForStoredPhones` ~976-1040, `startFromIdle` ~1079-1110)
- Create: `Sources/CaptureStudio/App/ToastPanel.swift`
- Create: `Sources/CaptureStudio/App/SessionIssueNotifier.swift` (contains `IssueToastPolicy`, `IssueToast`, `SessionIssueNotifier`)
- Modify: `Sources/CaptureStudio/App/RecordingSavedToast.swift` (use `ToastPanel`; behavior and position unchanged)
- Modify: `Sources/CaptureStudio/App/TrayPopupOpener.swift` (`isPopupOpen()` private → internal)
- Test: `Tests/CaptureStudioTests/IssueToastPolicyTests.swift`

**Interfaces:**
- Consumes: `PermissionCenter.shared` (Task 2), `PermissionPreflight` (Task 3), `RecordingSession.failurePermission` and `fail(_:permission:)` (Task 4), `PhoneBrowser.shared.localNetworkDenied` (Task 2).
- Produces:
  - `RecordingSession.arm(..., initialWarnings: [String] = [])` — keeps `warnings = []`, then a **separate** `warnings.append(contentsOf: initialWarnings)`, so a repeated warning (same text as the previous take's last list) still publishes as new.
  - `static let noSourceMessage = "Choose what to record in the Capture Studio menu first."` on `RecordingSession`.
  - `@MainActor final class ToastPanel { enum Placement { case topTrailing, topCenter }; init(identifier: String, placement: Placement, lifetime: TimeInterval); func show<Content: View>(_ content: Content); func dismiss(); func setHovering(_ hovering: Bool) }` — borderless non-activating `NSPanel` exactly as `RecordingSavedToast` builds it today (level `.statusBar`, `.canJoinAllSpaces/.fullScreenAuxiliary`, never key), 16 pt inset from `NSScreen.main.visibleFrame` top edge; `setHovering(true)` pauses auto-dismiss, `false` restarts it.
  - `enum IssueToastPolicy { static func newWarnings(previous: [String], current: [String]) -> [String]; static func failureTitle(previous: RecordingSession.State) -> String; static func visibleLines(_ lines: [String], max: Int = 3) -> [String] }`
  - `@MainActor enum IssueToast { static func show(title: String, lines: [String], isError: Bool, fix: PermissionKind?); static func dismiss() }` — `ToastPanel(identifier: "chrome.issueToast", placement: .topCenter, lifetime: 8)`.
  - `@MainActor final class SessionIssueNotifier { static let shared; func start(session: RecordingSession) }` (idempotent).

Policy rules: `newWarnings` returns the appended suffix when `current` starts with `previous`, otherwise all of `current` (a new arm reset the list). `failureTitle`: previous `.recording` or `.finishing` → `"Recording stopped early"`; anything else (including `.preparing`, where nothing was recorded yet) → `"Can't start recording"`. `visibleLines`: when `lines.count > max`, the first `max - 1` lines plus `"and \(lines.count - (max - 1)) more"`.

- [ ] **Step 1: Write the failing tests** in `IssueToastPolicyTests.swift`:

```swift
import Testing
import Foundation
@testable import CaptureStudio

@Test func appendedWarningsAreNew() {
    #expect(IssueToastPolicy.newWarnings(previous: ["a"], current: ["a", "b"]) == ["b"])
}
@Test func resetWarningsAreAllNew() {
    #expect(IssueToastPolicy.newWarnings(previous: ["a", "b"], current: ["c"]) == ["c"])
}
@Test func clearedOrUnchangedWarningsAreNotNew() {
    #expect(IssueToastPolicy.newWarnings(previous: ["a"], current: []).isEmpty)
    #expect(IssueToastPolicy.newWarnings(previous: ["a"], current: ["a"]).isEmpty)
}
@Test func failureTitles() {
    #expect(IssueToastPolicy.failureTitle(previous: .recording(startedAt: .distantPast)) == "Recording stopped early")
    #expect(IssueToastPolicy.failureTitle(previous: .finishing) == "Recording stopped early")
    #expect(IssueToastPolicy.failureTitle(previous: .idle) == "Can't start recording")
    #expect(IssueToastPolicy.failureTitle(previous: .arming) == "Can't start recording")
    #expect(IssueToastPolicy.failureTitle(previous: .preparing) == "Can't start recording")
    #expect(IssueToastPolicy.failureTitle(previous: .failed("x")) == "Can't start recording")
}
@Test func overflowCollapses() {
    #expect(IssueToastPolicy.visibleLines(["1", "2", "3"]) == ["1", "2", "3"])
    #expect(IssueToastPolicy.visibleLines(["1", "2", "3", "4", "5"]) == ["1", "2", "and 3 more"])
}
```

- [ ] **Step 2: Run** `swift test --filter IssueToastPolicyTests` → FAIL.
- [ ] **Step 3: Implement `IssueToastPolicy`** → `swift test --filter IssueToastPolicyTests` PASS.
- [ ] **Step 4: Start path.**
  - `startFromIdle`, `main == nil` (today a silent `guard let main else { return }` — a new user's popup never persists a display without the grant, so the hotkey lands here): `PermissionCenter.shared.refresh()`; screen not `.granted` → `fail(PermissionPreflight.screenOff, permission: .screenRecording)`; else `fail(Self.noSourceMessage)`.
  - `startFromIdle`, `main != nil`: replace the silent `guard Permissions.screenRecordingGranted() else { return }` with `PermissionCenter.shared.refresh()`; `issues = PermissionPreflight.issues(main:cameraID:micID:status: PermissionCenter.shared.status)`; first blocking issue → `fail(issue.message, permission: issue.kind); return` (no bundle is created). Non-blocking issues become `startWarnings`; a non-blocking `.camera` issue sets `camera = nil`, `.microphone` sets `mic = nil` (no prompt for an already-denied device), `.localNetwork` (`phoneOptionalOff`) sets a phone `camera`/`mic` to nil (otherwise `arm` adds a second "…not recorded: Phone not reachable." warning).
  - After the existing `requestCapture` prompts: camera refused for a local camera main → `fail(PermissionPreflight.cameraMainOff, permission: .camera)` (replaces "Camera access is required to record a camera."); refused overlay camera → `camera = nil` + `cameraOverlayOff`; refused mic → `mic = nil` + `micOff` (no duplicates). Pass `initialWarnings: startWarnings` to `arm`.
  - `waitForStoredPhones` timeout for a phone **main** (today "Phone not found…", ~1031-1035): if `PhoneBrowser.shared.localNetworkDenied` → `fail(PermissionPreflight.phoneMainOff, permission: .localNetwork)`; else keep today's message via `fail`. (The hotkey hits this before the preflight runs.)
- [ ] **Step 5: `ToastPanel` + refactor `RecordingSavedToast`** onto it (`identifier "chrome.savedToast"`, `.topTrailing`, lifetime 6). Make `TrayPopupOpener.isPopupOpen()` internal.
- [ ] **Step 6: `IssueToast` view:** orange `exclamationmark.triangle.fill` (warning) or red `xmark.octagon.fill` (error) icon; headline title; `visibleLines(lines)` as caption text; when `fix != nil` a small "Fix…" button → `Task { await PermissionCenter.shared.fix(kind) }` then dismiss; close `xmark` button; hover → `setHovering`; width 340, `.regularMaterial` rounded 12 like the saved toast.
- [ ] **Step 7: `SessionIssueNotifier.start(session:)`:**
  - Sink `session.$warnings` using the delivered value (remember the previous array; `new = newWarnings(...)`; if non-empty and `!TrayPopupOpener.isPopupOpen()` → `IssueToast.show(title: "Recording issue", lines: new, isError: false, fix: new.lazy.compactMap(PermissionPreflight.kind(forMessage:)).first)`). Warnings may be suppressed while the popup is open because it lists them.
  - Sink `session.$state` using the delivered value (remember the previous state). On **every** delivered `.failed(msg)` — `.failed → .failed` included, since each `fail()` is a new failure (e.g. a repeated hotkey press) — call `IssueToast.show(title: failureTitle(previous:), lines: [msg], isError: true, fix: session.failurePermission)`. `failurePermission` is already set because `fail()` assigns it before `state`. Failure toasts are **never** suppressed by the popup check: the GUI closes the popup right before `toggle`, and the window may still read as visible during its close animation.
  - Call `SessionIssueNotifier.shared.start(session: self)` at the end of `RecordingSession.init()` (not from `AppDelegate`, so it can never miss the session).
- [ ] **Step 8: Run** `swift test` → all PASS; `swift build` → succeeds.
- [ ] **Step 9: Commit** (with user OK) — `feat(recorder): visible start failures and capture-issue toasts`.

---

### Task 6: Onboarding window, launch hook, relaunch

**Files:**
- Modify: `Sources/CaptureStudio/App/LaunchRouting.swift`
- Create: `Sources/CaptureStudio/App/AppRelauncher.swift`
- Create: `Sources/CaptureStudio/App/PermissionOnboarding.swift` (launcher + `PermissionOnboardingView`)
- Modify: `Sources/CaptureStudio/App/CaptureStudioApp.swift` (fallback block and `applicationOpenUntitledFile`, right after `DashboardLauncher.show()`)
- Modify: `Sources/CaptureStudio/App/PermissionCenter.swift` (`fix(.screenRecording)` when `.denied`)
- Test: `Tests/CaptureStudioTests/LaunchRoutingTests.swift` (append), `Tests/CaptureStudioTests/AppRelauncherTests.swift`

**Interfaces:**
- Consumes: `PermissionCenter` (Task 2), `AppSettings.permissionOnboardingDone` (Task 1), `DockPresence`, `RecordingSession.shared`.
- Produces:
  - `LaunchRouting.shouldShowPermissionOnboarding(isLoginItem: Bool, onboardingDone: Bool, coreGranted: Bool) -> Bool` = `!isLoginItem && !onboardingDone && !coreGranted`.
  - `enum AppRelauncher { static func shellArguments(pid: Int32, bundlePath: String) -> [String]; static func isSafe(state: RecordingSession.State) -> Bool; @MainActor static func relaunch() }` — `isSafe` is true only for `.idle` and `.failed` (quitting mid-take loses it: `tearDownForQuit` does not finalize a recording).
  - `@MainActor enum PermissionOnboarding { static func show(); static func showIfNeeded(isLoginItem: Bool) }`

- [ ] **Step 1: Write the failing tests.** Append to `LaunchRoutingTests.swift`:

```swift
@Test func onboardingShowsOnFirstPlainLaunchWithMissingGrant() {
    #expect(LaunchRouting.shouldShowPermissionOnboarding(isLoginItem: false, onboardingDone: false, coreGranted: false))
}
@Test func onboardingSkippedForLoginItem() {
    #expect(!LaunchRouting.shouldShowPermissionOnboarding(isLoginItem: true, onboardingDone: false, coreGranted: false))
}
@Test func onboardingSkippedWhenDone() {
    #expect(!LaunchRouting.shouldShowPermissionOnboarding(isLoginItem: false, onboardingDone: true, coreGranted: false))
}
@Test func onboardingSkippedWhenAllGranted() {
    #expect(!LaunchRouting.shouldShowPermissionOnboarding(isLoginItem: false, onboardingDone: false, coreGranted: true))
}
```

`AppRelauncherTests.swift`:

```swift
import Testing
@testable import CaptureStudio

@Test func relaunchPassesPathAsArgumentNotScript() {
    let path = "/Apps/My \"Odd\" App.app"
    let args = AppRelauncher.shellArguments(pid: 42, bundlePath: path)
    #expect(args.count == 4)
    #expect(args[0] == "-c")
    #expect(!args[1].contains("Odd"))   // path never interpolated into the script
    #expect(args[2] == "42")
    #expect(args[3] == path)
}

@Test func relaunchOnlyWhenNothingIsRecording() {
    #expect(AppRelauncher.isSafe(state: .idle))
    #expect(AppRelauncher.isSafe(state: .failed("x")))
    #expect(!AppRelauncher.isSafe(state: .armed))
    #expect(!AppRelauncher.isSafe(state: .recording(startedAt: .distantPast)))
    #expect(!AppRelauncher.isSafe(state: .finishing))
}
```

- [ ] **Step 2: Run** `swift test --filter LaunchRoutingTests` and `--filter AppRelauncherTests` → FAIL.
- [ ] **Step 3: Implement** `shouldShowPermissionOnboarding` and `AppRelauncher`: script `while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$1"`, args `["-c", script, String(pid), bundlePath]`. `relaunch()`: if `Bundle.main.bundleURL.pathExtension != "app"`, or `RecordingSession.shared` exists and `!isSafe(state:)`, log and return; run `/bin/sh` via `Process` with `shellArguments(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: Bundle.main.bundlePath)`; on success `NSApp.terminate(nil)`.
- [ ] **Step 4: Run** both filters → PASS.
- [ ] **Step 5: Implement `PermissionOnboarding`:** singleton window modeled on `DashboardLauncher.show()` — reuse if open (`makeKeyAndOrderFront`, `NSApp.activate`); else `NSWindow(contentViewController: NSHostingController(rootView: PermissionOnboardingView()))`, identifier `"chrome.permissionOnboarding"`, title `"Set Up Capture Studio"`, style `[.titled, .closable]`, `center()`, `isReleasedWhenClosed = false`, `DockPresence.shared.retain()` on open and `release()` + `AppSettings.permissionOnboardingDone = true` on `willClose`. Do **not** register with `CaptureContentWindows`. `showIfNeeded(isLoginItem:)`: `coreGranted` = screen, mic, camera all `.granted` in `PermissionCenter.shared`; if `shouldShowPermissionOnboarding(...)` → `show()`; else if `coreGranted` → mark done.
- [ ] **Step 6: Implement `PermissionOnboardingView`** (observes `PermissionCenter.shared`):

```
Capture Studio needs a few permissions                 (headline)
You can change these anytime in System Settings → Privacy & Security.   (caption, secondary)
─────────────────────────────────────────────
[icon] Screen Recording      Required to record your screen and system audio.   [status/action]
[icon] Microphone            Optional — record your voice.                       [status/action]
[icon] Camera                Optional — record your webcam alongside the screen. [status/action]
[icon] Local Network         Optional — use your phone as a camera or microphone.[status/action]
─────────────────────────────────────────────
                                                            [Done]
```

  Icons: `rectangle.dashed.badge.record`, `mic`, `video`, `wifi`. Action by status: `.granted` → green `checkmark.circle.fill` + "Allowed"; `.notDetermined` → "Allow" (`await center.request(kind)`); `.denied` → "Open Settings" (`center.openSettings(kind)`), and for Screen Recording also "Relaunch" (`AppRelauncher.relaunch()`, disabled unless `AppRelauncher.isSafe(state:)` for the current session state) with caption "After allowing, relaunch Capture Studio so macOS applies it."; `.unknown` (Local Network) → "Check" (`await center.request(.localNetwork)`) with caption "macOS asks the first time Capture Studio looks for your phone." "Done" is the default action and closes the window.
- [ ] **Step 7: Launch hook:** in `AppDelegate`, after each launch-routing `DashboardLauncher.show()` (fallback block and `applicationOpenUntitledFile`), call `PermissionOnboarding.showIfNeeded(isLoginItem: isLoginItemLaunch)`. Not on Dock reopen, not on document open.
- [ ] **Step 7b: Screen Fix leads to Relaunch:** in `PermissionCenter.fix`, `.screenRecording` + `.denied` → `PermissionOnboarding.show()` first, then `openSettings(.screenRecording)` (Settings ends up in front; the onboarding window with Relaunch waits behind it for the user's return — covers "granted, pending relaunch", where Settings alone offers nothing).
- [ ] **Step 8: Run** `swift test` → all PASS; `swift build` → succeeds.
- [ ] **Step 9: Commit** (with user OK) — `feat(app): first-run permission onboarding window`.

---

### Task 7: Popup + Dashboard integration

**Files:**
- Modify: `Sources/CaptureStudio/App/RecorderMenuView.swift`
- Create: `Sources/CaptureStudio/Dashboard/PermissionBanner.swift`
- Modify: `Sources/CaptureStudio/Dashboard/DashboardView.swift` (`body`: banner between `toolbar` and `Divider()`)
- Test: `Tests/CaptureStudioTests/PermissionBannerTests.swift`

**Interfaces:**
- Consumes: `PermissionCenter` (Task 2), `PermissionPreflight` (Task 3), `PermissionOnboarding.show()` and `AppRelauncher.relaunch()` (Task 6), `TrayPopupOpener.closePopup()`.
- Produces: `struct PermissionBanner: View` with `nonisolated static func message(status: (PermissionKind) -> PermissionStatus) -> String?`.

Banner rule — Screen Recording only: screen ≠ `.granted` → `"Screen Recording is off — Capture Studio can't record your screen."`; otherwise nil (no banner). Mic/camera denial is a deliberate user choice; nagging about it on every Dashboard open is an anti-goal (the per-take preflight warning covers it). Screen-only also keeps the banner out of `screen.mp4`: the Dashboard is a registered content window, but without the grant nothing can be recorded. Button "Set Up…" → `PermissionOnboarding.show()`.

- [ ] **Step 1: Write the failing tests** in `PermissionBannerTests.swift`:

```swift
import Testing
@testable import CaptureStudio

@Test func bannerHiddenWhenAllGranted() {
    #expect(PermissionBanner.message(status: { _ in .granted }) == nil)
}
@Test func bannerPrefersScreen() {
    #expect(PermissionBanner.message(status: { _ in .denied })
            == "Screen Recording is off — Capture Studio can't record your screen.")
    #expect(PermissionBanner.message(status: { $0 == .screenRecording ? .notDetermined : .granted })
            == "Screen Recording is off — Capture Studio can't record your screen.")
}
@Test func bannerIgnoresEverythingButScreen() {
    #expect(PermissionBanner.message(status: { $0 == .screenRecording ? .granted : .denied }) == nil)
}
```

- [ ] **Step 2: Run** `swift test --filter PermissionBannerTests` → FAIL.
- [ ] **Step 3: Implement `PermissionBanner`** (observes `PermissionCenter.shared`; orange `exclamationmark.triangle.fill`, message, trailing "Set Up…" button; thin bar, hidden when `message` is nil) and insert it into `DashboardView.body`.
- [ ] **Step 4: Run** `swift test --filter PermissionBannerTests` → PASS.
- [ ] **Step 5: Popup permission source:** replace `@State private var permissionGranted = Permissions.screenRecordingGranted()` with `@ObservedObject private var permissions = PermissionCenter.shared` and a computed `permissionGranted: Bool { permissions.isGranted(.screenRecording) }`. Every existing "Request" button calls `Task { await permissions.fix(.screenRecording); await refreshDevices() }` instead of assigning `permissionGranted`. First line of the main `.task`: `permissions.refresh()`. Add `.onChange(of: permissionGranted) { _, granted in if granted { Task { await refreshDevices() } } }`. `permissionView` gains a "Relaunch" button (`AppRelauncher.relaunch()`) after "Open Settings", disabled unless `AppRelauncher.isSafe(state: session.state)`.
- [ ] **Step 6: Popup preflight rows:** extract the `main: MainSource?` the Preview button's action computes today (~401-405: camera main → `mainSource`; Area mode → saved display or `mainSource`; Full → `mainSource`) into one computed property `previewMain`, used by both the button action and the rows. In `idleView`, directly above the Preview button, when `previewMain` is non-nil render `PermissionPreflight.issues(main: previewMain, cameraID: selectedCameraID, micID: selectedMicID, status: permissions.status)`: each row is a caption `Label(issue.message, systemImage: issue.blocking ? "xmark.octagon" : "exclamationmark.triangle")` in red/orange plus a small "Fix" button → `Task { await permissions.fix(issue.kind) }`. Extend the Preview button's `.disabled(...)` with `|| issues.contains(where: \.blocking)`.
- [ ] **Step 7: Popup footer + phone help:** add an icon-only footer button `Image(systemName: "lock.shield")` with `.help("Permissions…")` → `TrayPopupOpener.closePopup(); PermissionOnboarding.show()`, placed before the Quit spacer. In the phone-help popover, when `permissions.status(.localNetwork) == .denied`, append orange text "Local Network access is off — phones can't be found." and an "Open Settings" button → `permissions.openSettings(.localNetwork)`.
- [ ] **Step 8: Run** `swift test` → all PASS; `swift build` → succeeds.
- [ ] **Step 9: Commit** (with user OK) — `feat(app): live permission status in popup and Dashboard`.

---

### Task 8: Final verification

- [ ] **Step 1:** `swift test` → all tests pass (previous count + new suites), 0 failures.
- [ ] **Step 2:** `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test` → same, 0 failures.
- [ ] **Step 3:** `scripts/build-app.sh debug` → `dist/CaptureStudio.app` built and signed; `pkill -x CaptureStudio; open dist/CaptureStudio.app` launches to Dashboard.
- [ ] **Step 4:** `rtk proxy grep -rn "CaptureContentWindows.shared.register" Sources` → only the existing Studio/Dashboard call sites (no new chrome registered).
- [ ] **Step 4b:** `rtk proxy grep -n "state = .failed" Sources/CaptureStudio/Recorder/RecordingSession.swift` → exactly one hit (inside `fail`).
- [ ] **Step 5:** Report to the user, listing optional manual checks (do not block on them): fresh TCC (`tccutil reset ScreenCapture dev.wadjakorn.capture-studio`, same for `Microphone`, `Camera`) → onboarding shows; hotkey with screen off on a fresh install (never opened the popup) → "Can't start recording" toast + Fix; deny mic → popup shows the micOff row before Preview; via hotkey → warning toast; recording has no mic track; record twice with mic denied → the warning toasts both times; unplug USB mic mid-take → "Microphone disconnected." toast, `meta.json` mic `truncated: true`; toggle Screen Recording off mid-take → saved partial + "Recording stopped early" toast (if macOS offers "Quit & Reopen" here, note it: quitting mid-take is a known pre-existing loss, see ledger); stop via the macOS screen-sharing menu → normal save, no failure toast; deny Local Network → phone help shows the hint (confirms `NWBrowser` really reports `.waiting(.dns(-65570))` on this macOS; if not, the status just stays "unknown").

---

## Scrutiny ledger (2026-11-27)

Independent reviewer findings, and what this plan now does:

| # | Finding | Resolution |
|---|---------|------------|
| 1 | Blocker: `completeSave` goes `.idle → .failed`, so every mid-take failure toast would read "Can't start recording" | Task 4 Step 4: final state decided once, `.finishing → .failed` directly |
| 2 | Hotkey with no grant is still silent for new users (`main == nil` guard) | Task 5 Step 4: `main == nil` → `screenOff` or `noSourceMessage` |
| 3 | `.failed → .failed` never toasted | Task 5 Step 7: toast on every delivered `.failed` |
| 4 | Upgrader who revokes reads `.notDetermined` → dead Fix click | Task 2: `refresh()` sets `screenRecordingRequested` whenever granted; residual gap documented |
| 5 | Sink reads stale `PhoneBrowser` values (willSet) | Global Constraints + Task 2: `.receive(on: DispatchQueue.main)` |
| 6 | Hotkey hits "Phone not found" before preflight; duplicate phone warnings | Task 5 Step 4: `waitForStoredPhones` → `phoneMainOff`; phone sources nil'd on `phoneOptionalOff` |
| 7 | Stale `failurePermission` on later failures | Task 4: single `fail(_:permission:)` helper for all 16 sites; Task 8 Step 4b grep |
| 8 | Repeated pre-record warning not toasted on later takes | Task 5: `arm` clears, then appends `initialWarnings` separately |
| 9 | Quit/relaunch while recording loses the take (pre-existing `tearDownForQuit`) | Out of scope (spec non-goal, follow-up); Relaunch gated by `AppRelauncher.isSafe` |
| 10 | `.preparing` start failures mislabeled, no Fix | Task 5 title rule; Task 4 Step 4 classifies `beginRecording` screen start errors |
| 11 | GUI closes popup then fails → toast could be suppressed | Task 5 Step 7: failure toasts never suppressed; Task 7 disables Preview on a blocking issue |
| 12 | Language mode is `.v5`, not 6 | Tech Stack + Global Constraints corrected; `nonisolated static` for View helpers |
| 13 | Notifier read `RecordingSession.shared` once at launch | Task 5 Step 7: started from `RecordingSession.init()` |
| 14 | Screen Fix in "granted, pending relaunch" opens Settings only | Task 6 Step 7b: Fix shows onboarding (Relaunch) + Settings |
| 15 | Permanent mic/camera banner nags; Dashboard is captured content | Task 7: banner is Screen Recording only |
| 16 | Popup Relaunch not gated | Task 7 Step 5 + `relaunch()` itself refuses when unsafe |
| 17 | Popup preflight `main` ambiguous | Task 7 Step 6: shared `previewMain` |
| 18 | `NWBrowser` denial shape unverified at runtime | Kept `.unknown` fallback; added to manual checks |

Verified correct by the reviewer: all `SCStreamError.Code` cases used exist at macOS 15 in both the Xcode and CLT SDKs; `-65570` = `kDNSServiceErr_PolicyDenied`; `NWError.dns(-65570)` compiles; `arm()` has one caller; `stop()` after a user stop is safe (`try? stopCapture`); camera-main never reaches `ScreenStreamFailure`; toast/onboarding stay out of `screen.mp4` (app excluded wholesale); relaunch `sh -c` argument mapping; all cited line numbers.
