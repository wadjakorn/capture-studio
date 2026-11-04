# Phone Camera Sources + Any Camera as Main Video — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phone (Samsung Galaxy first) cameras and mics record reliably, and any camera can be the main video with a second camera as the front overlay.

**Architecture:** Part A hardens `DeviceDiscovery`/`CameraRecorder` for UVC and virtual cameras and adds hot-plug refresh + labeling in the tray popup. Part B introduces `MainSource` (display or camera) through `AppSettings` → `RecorderMenuView` → `RecordingSession`, writes a `role`-tagged main camera track into the bundle, and teaches Studio/Dashboard to resolve the main track through `ProjectMeta.mainTrack` instead of hardcoded `screen.mp4`.

**Tech Stack:** Swift 6 (CLT toolchain), SwiftUI/AppKit, AVFoundation, swift-testing 0.12.0.

**Spec:** `docs/superpowers/specs/2026-11-04-phone-camera-and-main-source-design.md`

## Global Constraints

- Command Line Tools only. swift-testing `0.12.0` and KeyboardShortcuts `1.10.0` exact. No new dependencies.
- macOS 15+. Use `AVCaptureDevice.DeviceType.external` (not `.externalUnknown`).
- `DisplayInfo` schema never changes, only values.
- Every track stamps `sessionStartHostTime`; alignment is offset arithmetic. CameraRecorder audio-gate / monotonic PTS logic stays intact.
- Old bundles (no `role`, no `mainSource`) must load exactly as today. New bundles with display main must have identical meta semantics to today plus the new optional fields.
- `swift build` and `swift test` green at every commit. Commits need explicit user confirmation (CLAUDE.md); plan steps say "Commit" meaning "ask, then commit".
- Camera-main mode: no system audio, no area selection, no events.jsonl.

## Review Focus

1. Opening a pre-existing bundle (no `role` field) → Studio resolves `screen.mp4` as main and `camera.mp4` as overlay exactly as before. Test in Task 6.
2. Camera-main bundle with a portrait phone (1080×1920) → Studio canvas is portrait, PiP placement math uses the real render size. Test in Task 6 (meta resolution) + Task 8 composition change + manual check in Task 11.
3. Main camera selected and the same device chosen as front camera → picker must not allow it; `arm()` must drop the overlay rather than open the device twice. Test in Task 7 (`RecorderSelection`) and guard in Task 9 Step 2.
4. USB phone yanked mid-recording → camera track finalizes with `truncated: true`, recording still saves, warning shown. Covered by Task 4 observer wiring; manual check in Task 11.
5. Hotkey start with `lastMainSource == .camera(id)` whose device is now missing → session goes `.failed("Selected camera is no longer available.")`, never silently records the display. Pure test on `MainSource.resolve(cameraIDs:displayIDs:)` in Task 7; state machine checked manually in Task 11.

---

## File map

| File | Change |
|---|---|
| `Sources/CaptureStudio/Recorder/DeviceDiscovery.swift` | add `DeviceKind` classifier + `CameraFormatChooser` |
| `Sources/CaptureStudio/Recorder/CameraRecorder.swift` | preset fallback, explicit settings fallback, disconnect/runtime-error observers, `writtenPixelSize` |
| `Sources/CaptureStudio/Recorder/MainSource.swift` (new) | `MainSource` enum, `MainSource.resolve`, `RecorderSelection` helpers |
| `Sources/CaptureStudio/App/AppSettings.swift` | `lastMainSource` (lives here: `set(_:forKey:)` is private) |
| `Sources/CaptureStudio/App/RecorderMenuView.swift` | Main picker, Front camera picker, hot-plug refresh, phone groups, help popover |
| `Sources/CaptureStudio/App/CameraPreviewPanel.swift` | `placement` parameter (corner / bottom-center large) |
| `Sources/CaptureStudio/Recorder/RecordingSession.swift` | `arm(main:)`, `armedMain`, `mainCameraRecorder`, `mainPreviewPanel`, camera-main branches in every state function |
| `Sources/CaptureStudio/ProjectBundle/Meta.swift` | `TrackRole`, `TrackInfo.role`, `ProjectMeta.mainSource`, `mainTrack`, `overlayCameraTrack` |
| `Sources/CaptureStudio/ProjectBundle/ProjectBundle.swift` | `mainCameraURL`, `url(for:)` |
| `Sources/CaptureStudio/Studio/StudioModel.swift:650-750`, `:1434-1449`, `:3080`; `Studio/StudioWindow.swift:292` | composition via `mainTrack`; gate auto-zoom + zoom lane on `hasCursorData`; Reveal in Finder |
| `Sources/CaptureStudio/Dashboard/ThumbnailStore.swift`, `ProjectLibrary.swift`, `DashboardView.swift` | main-track file, badge |
| `Tests/CaptureStudioTests/DeviceKindTests.swift`, `CameraFormatChooserTests.swift`, `MainSourceTests.swift`, `MetaRoleTests.swift`, `RecorderSelectionTests.swift` (new) | pure-logic tests |

---

## Part A — phone sources

### Task 1: Verify baseline with a real phone (spike, no code)

**Files:** none.

- [ ] **Step 1:** Build and run: `scripts/build-app.sh debug && pkill -x CaptureStudio; open dist/CaptureStudio.app`.
- [ ] **Step 2:** Connect a Galaxy in USB webcam mode (S26 / One UI 8.5) **or** start Iriun/Camo on any Galaxy + its macOS app. Open the tray popup, press Refresh.
- [ ] **Step 3:** Record 10 s with the phone as Camera and (if a virtual mic exists) as Microphone. Open in Studio.
- [ ] **Step 4:** Write findings into the spec under "Ground truth → Baseline check": listed? name shown? recorded? mic worked? which `localizedName`/`manufacturer`/`modelID` strings the phone reports (needed for Task 2 heuristics). If camera failed, paste the log line from `Log.recorder`.

Expected: phone listed (it is `.external`). If not listed, stop and report before Task 2.

### Task 2: `DeviceKind` classifier

**Files:**
- Modify: `Sources/CaptureStudio/Recorder/DeviceDiscovery.swift`
- Test: `Tests/CaptureStudioTests/DeviceKindTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum DeviceKind: String, CaseIterable { case builtIn, phone, external, virtual }
  extension DeviceKind {
      /// Pure. `deviceType` is the raw `AVCaptureDevice.DeviceType.rawValue`.
      static func classify(name: String, manufacturer: String?, modelID: String?,
                           deviceType: String) -> DeviceKind
      var groupTitle: String   // "Built-in", "Phone", "External", "Virtual"
  }
  extension DeviceDiscovery {
      static func kind(of device: AVCaptureDevice) -> DeviceKind
      /// Stable group order: builtIn, phone, external, virtual; name order within.
      static func grouped(_ devices: [AVCaptureDevice]) -> [(kind: DeviceKind, devices: [AVCaptureDevice])]
  }
  ```

- [ ] **Step 1: Write failing tests**

```swift
@Test func continuityCameraIsPhone() {
    #expect(DeviceKind.classify(name: "iPhone", manufacturer: "Apple Inc.", modelID: "Continuity Camera",
                                deviceType: "AVCaptureDeviceTypeContinuityCamera") == .phone)
}
@Test func galaxyUVCIsPhone() {
    #expect(DeviceKind.classify(name: "Galaxy S26 Ultra", manufacturer: "Samsung", modelID: "UVC Camera VendorID_1256",
                                deviceType: "AVCaptureDeviceTypeExternal") == .phone)
}
@Test func iriunIsPhone() {
    #expect(DeviceKind.classify(name: "Iriun Webcam", manufacturer: nil, modelID: nil,
                                deviceType: "AVCaptureDeviceTypeExternal") == .phone)
}
@Test func obsVirtualIsVirtual() {
    #expect(DeviceKind.classify(name: "OBS Virtual Camera", manufacturer: nil, modelID: nil,
                                deviceType: "AVCaptureDeviceTypeExternal") == .virtual)
}
@Test func logitechIsExternal() {
    #expect(DeviceKind.classify(name: "Logitech BRIO", manufacturer: "Logitech", modelID: "UVC Camera VendorID_1133",
                                deviceType: "AVCaptureDeviceTypeExternal") == .external)
}
@Test func macbookMicIsBuiltIn() {
    #expect(DeviceKind.classify(name: "MacBook Pro Microphone", manufacturer: "Apple Inc.", modelID: nil,
                                deviceType: "AVCaptureDeviceTypeMicrophone") == .builtIn)
}
@Test func facetimeIsBuiltIn() {
    #expect(DeviceKind.classify(name: "FaceTime HD Camera", manufacturer: "Apple Inc.", modelID: "FaceTime HD Camera",
                                deviceType: "AVCaptureDeviceTypeBuiltInWideAngleCamera") == .builtIn)
}
```

- [ ] **Step 2:** `swift test --filter DeviceKindTests` → FAIL (type missing).
- [ ] **Step 3:** Implement. Rules in order: deviceType continuityCamera → `.phone`; deviceType builtIn* → `.builtIn`; name contains "MacBook", "iMac", "Mac mini", "Mac Studio", "Built-in" → `.builtIn` (covers `.microphone` devices, whose deviceType never says builtIn); case-insensitive match of name/manufacturer/modelID against `["samsung","galaxy","android","iriun","droidcam","camo","epoccam","iphone","ipad","pixel"]` → `.phone`; match against `["virtual","obs","snap camera","mmhmm"]` → `.virtual`; else `.external`. Add any strings recorded in Task 1.
- [ ] **Step 4:** `swift test --filter DeviceKindTests` → PASS.
- [ ] **Step 5:** Commit `feat(recorder): classify capture devices by kind for picker grouping`.

### Task 3: `CameraFormatChooser` + CameraRecorder fallbacks

**Files:**
- Modify: `Sources/CaptureStudio/Recorder/DeviceDiscovery.swift` (chooser), `Sources/CaptureStudio/Recorder/CameraRecorder.swift:95-125` (warmUp), `:127-147` (beginWriting)
- Test: `Tests/CaptureStudioTests/CameraFormatChooserTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct CameraFormatCandidate: Equatable { var width: Int; var height: Int; var maxFPS: Double; var index: Int }
  enum CameraFormatChooser {
      /// Highest-resolution candidate with max(width,height) <= maxEdge; ties → highest maxFPS, then lowest index. nil if empty.
      static func best(_ candidates: [CameraFormatCandidate], maxEdge: Int = 1920) -> CameraFormatCandidate?
  }
  ```
  `CameraRecorder` gains `private(set) var writtenPixelSize: CGSize?` (set in `beginWriting` from the settings dictionary width/height).

- [ ] **Step 1: Failing tests**

```swift
@Test func prefers1080pOver4K() {
    let c = [CameraFormatCandidate(width: 3840, height: 2160, maxFPS: 30, index: 0),
             CameraFormatCandidate(width: 1920, height: 1080, maxFPS: 30, index: 1)]
    #expect(CameraFormatChooser.best(c)?.index == 1)
}
@Test func tieBreaksOnFPS() {
    let c = [CameraFormatCandidate(width: 1280, height: 720, maxFPS: 30, index: 0),
             CameraFormatCandidate(width: 1280, height: 720, maxFPS: 60, index: 1)]
    #expect(CameraFormatChooser.best(c)?.index == 1)
}
@Test func portraitEdgeLimit() {
    let c = [CameraFormatCandidate(width: 1080, height: 1920, maxFPS: 30, index: 0),
             CameraFormatCandidate(width: 2160, height: 3840, maxFPS: 30, index: 1)]
    #expect(CameraFormatChooser.best(c)?.index == 0)
}
@Test func emptyIsNil() { #expect(CameraFormatChooser.best([]) == nil) }
```

- [ ] **Step 2:** `swift test --filter CameraFormatChooserTests` → FAIL.
- [ ] **Step 3:** Implement chooser.
- [ ] **Step 4:** In `warmUp()`: `canSetSessionPreset` is meaningless before inputs exist (today the preset is set at `:104` before `addInput` at `:108`, so it always returns true). Reorder: `beginConfiguration` → `addInput` → `if session.canSetSessionPreset(.high) { .high } else { .inputPriority; device.lockForConfiguration(); device.activeFormat = chooser pick; unlock }` → `addOutput` → `commitConfiguration`. Map each `AVCaptureDevice.Format` via `CMVideoFormatDescriptionGetDimensions` and `videoSupportedFrameRateRanges.map(\.maxFrameRate).max()`.
- [ ] **Step 5:** In `beginWriting()`: when `recommendedVideoSettingsForAssetWriter` is nil, build `[AVVideoCodecKey: .h264, AVVideoWidthKey: w, AVVideoHeightKey: h]` from the active format dimensions (only reached on the `.inputPriority` path, where activeFormat dims are the buffer dims). `writtenPixelSize` is always read from the dictionary actually handed to `AVAssetWriterInput`, never from `activeFormat`.
- [ ] **Step 6:** `swift test` → PASS; `swift build` → OK.
- [ ] **Step 7:** Commit `fix(recorder): choose a safe camera format for UVC and virtual cameras`.

### Task 4: Disconnect / runtime-error handling in CameraRecorder

**Files:**
- Modify: `Sources/CaptureStudio/Recorder/CameraRecorder.swift` (observers in `warmUp`, removal in `stop`/`discard`), `Sources/CaptureStudio/Recorder/RecordingSession.swift:765-772` (warning text)

**Interfaces:**
- Produces: `CameraRecorder.onDeviceLost: (@Sendable (String) -> Void)?` fired once with a human message ("Camera disconnected." / "Camera error: …"). `markTruncated()` is called internally before the callback.

- [ ] **Step 1:** In `warmUp()` after `startRunning`, register with `NotificationCenter.default.addObserver(self, selector:name:object:)` (CameraRecorder is an `NSObject`; selector-based avoids Sendable-capture warnings): `AVCaptureDevice.wasDisconnectedNotification` (object nil; in the handler compare `(note.object as? AVCaptureDevice)?.uniqueID` against `device.uniqueID` / `micDevice?.uniqueID`), `.AVCaptureSessionRuntimeError` (object == `session`). Handler: `markTruncated()`, set a `deviceLost` flag via `queue.sync` so `appendVideo`/`appendAudio` early-return, fire `onDeviceLost` once (guard with a `deviceLostReported` bool).
- [ ] **Step 2:** Remove observers in `stop()` and `discard()`.
- [ ] **Step 3:** In `RecordingSession.arm`, set `recorder.onDeviceLost = { [weak self] msg in Task { @MainActor in self?.warnings.append(msg) } }`. Recording continues (screen/main track untouched).
- [ ] **Step 4:** `swift build` → OK; `swift test` → PASS (no new pure tests; behavior verified in Task 11 manual run).
- [ ] **Step 5:** Commit `fix(recorder): mark the camera track truncated when the device disappears`.

### Task 5: Tray popup — hot-plug refresh, grouped pickers, phone help

**Files:**
- Modify: `Sources/CaptureStudio/App/RecorderMenuView.swift:258-290` (pickers), `:607-625` (refreshDevices)

- [ ] **Step 1:** Add `.onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification))` and `wasDisconnectedNotification` on `recorderView` → `Task { await refreshDevices() }`.
- [ ] **Step 2:** Replace the flat `ForEach(cameras)` / `ForEach(microphones)` with `DeviceDiscovery.grouped(...)`: a `Text(group.kind.groupTitle).font(.caption2)` header followed by `pickRow`s. Skip the header when only one group exists.
- [ ] **Step 3:** Add a `?` button beside the camera picker label opening a `.popover` with the static copy:
  > **Use your phone as a camera**
  > Any Android phone: install Capture Studio Phone, join the same Wi-Fi, open the app — it appears here.
  > Galaxy S26 (One UI 8.5+) can also plug in via USB-C: choose "Webcam" in the USB notification (video only, no mic).
- [ ] **Step 4:** `refreshDevices()` (`:607-625`): (a) drop the `guard permissionGranted` for cameras/mics — enumerate them always; only the `displays()` call stays behind the permission (spec B0). (b) Seed `selectedCameraID`/`selectedMicID` from `AppSettings` only on first load (`@State private var seeded = false`), not on every refresh, so a hot-plug refresh can't resurrect a selection the user set to None. (c) When a selected device vanishes, clear the `@State` only; do not write `AppSettings`. (d) Remove the `.onChange` writes at `:102-103`; instead write `AppSettings.lastCameraID`/`lastMicID` inside the `pickRow` actions (`:263-269`, `:277-283`) including the "None" rows (write `nil`). Net effect: None persists, unplug/replug restores.
- [ ] **Step 5:** `swift build` → OK. Manual: open popup, plug phone → appears without Refresh.
- [ ] **Step 6:** Commit `feat(recorder): hot-plug device refresh, grouped pickers and phone help`.

---

## Part B — any camera as main video

Order matters: Task 6 (format) → Task 7 (model) → Task 8 (Studio/Dashboard readers, depends only on Task 6) → Task 9 (session) → Task 10 (popup UI). Task 8 lands before Task 9 so a camera-main bundle is never written by a build that cannot open it.

### Task 6: Bundle format — `TrackRole`, `mainTrack`, `url(for:)`

**Files:**
- Modify: `Sources/CaptureStudio/ProjectBundle/Meta.swift`, `Sources/CaptureStudio/ProjectBundle/ProjectBundle.swift`
- Test: `Tests/CaptureStudioTests/MetaRoleTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum TrackRole: String, Codable { case main, overlay }
  struct TrackInfo { ... var role: TrackRole? = nil }          // encodeIfPresent; decodeIfPresent
  struct ProjectMeta {
      ... var mainSource: String? = nil                           // "display" | "camera"
      var mainTrack: TrackInfo?            // role == .main ?? first .screen
      var overlayCameraTrack: TrackInfo?   // first .camera with role != .main
      var isCameraMain: Bool               // mainTrack?.type == .camera
  }
  extension DisplayInfo { static func synthetic(width: Int, height: Int) -> DisplayInfo }  // displayID 0, point = pixel, scale 1, origin 0
  extension ProjectBundle {
      var mainCameraURL: URL               // main-camera.mp4
      func url(for track: TrackInfo) -> URL   // url.appendingPathComponent(track.filename)
  }
  ```

- [ ] **Step 1: Failing tests**

```swift
@Test func legacyMetaResolvesScreenAsMain() throws {
    // Note: synthesized Decodable requires "truncated" (default values are not honored).
    let json = """
    {"schemaVersion":1,"app":{"version":"dev","macOSVersion":"15.0"},
     "display":{"displayID":1,"pixelWidth":100,"pixelHeight":50,"pointWidth":100,"pointHeight":50,"scaleFactor":1,"originX":0,"originY":0},
     "tracks":[{"type":"camera","filename":"camera.mp4","sessionStartHostTime":1,"codec":"h264","truncated":false},
               {"type":"screen","filename":"screen.mp4","sessionStartHostTime":0,"codec":"hevc","truncated":false}],
     "recordedAt":"2026-01-01T00:00:00Z"}
    """
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let meta = try decoder.decode(ProjectMeta.self, from: Data(json.utf8))
    #expect(meta.mainTrack?.filename == "screen.mp4")
    #expect(meta.overlayCameraTrack?.filename == "camera.mp4")
    #expect(meta.isCameraMain == false)
    #expect(meta.mainSource == nil)
}
@Test func cameraMainResolvesByRole() {
    let main = TrackInfo(type: .camera, filename: "main-camera.mp4", sessionStartHostTime: 0, codec: "h264", role: .main)
    let overlay = TrackInfo(type: .camera, filename: "camera.mp4", sessionStartHostTime: 0.2, codec: "h264", role: .overlay)
    let meta = ProjectMeta(schemaVersion: 2, app: .current(), display: .synthetic(width: 1080, height: 1920),
                           tracks: [overlay, main], recordedAt: .now, mainSource: "camera")
    #expect(meta.mainTrack == main)
    #expect(meta.overlayCameraTrack == overlay)
    #expect(meta.isCameraMain)
}
@Test func roleRoundTripsAndOmitsWhenNil() throws {
    let t = TrackInfo(type: .screen, filename: "screen.mp4", sessionStartHostTime: 0, codec: "hevc")
    let data = try JSONEncoder().encode(t)
    #expect(!String(decoding: data, as: UTF8.self).contains("role"))
    let back = try JSONDecoder().decode(TrackInfo.self, from: data)
    #expect(back.role == nil)
}
@Test func syntheticDisplayInfo() {
    let d = DisplayInfo.synthetic(width: 1080, height: 1920)
    #expect(d.displayID == 0 && d.pixelWidth == 1080 && d.pointHeight == 1920 && d.scaleFactor == 1)
}
```

- [ ] **Step 2:** `swift test --filter MetaRoleTests` → FAIL.
- [ ] **Step 3:** Implement. `TrackInfo` and `ProjectMeta` get explicit `CodingKeys` + `init(from:)`/`encode(to:)` so `role`/`mainSource` use `decodeIfPresent`/`encodeIfPresent` and the existing `truncated` default also becomes `decodeIfPresent` (no behavior change for today's writer, which always emits it).
- [ ] **Step 4:** `swift test` → PASS (including `ProjectBundleTests`, `EditStateTests`, `ProjectLibraryTests`).
- [ ] **Step 5:** Commit `feat(bundle): track roles and main-track resolution`.

### Task 7: `MainSource`, resolver, selection helpers, settings

**Files:**
- Create: `Sources/CaptureStudio/Recorder/MainSource.swift`
- Modify: `Sources/CaptureStudio/App/AppSettings.swift` (add `lastMainSource` here — `set(_:forKey:)` at `:84` is private)
- Test: `Tests/CaptureStudioTests/MainSourceTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum MainSource: Equatable {
      case display(CGDirectDisplayID)
      case camera(uniqueID: String)
      var displayID: CGDirectDisplayID?    // nil for camera
      var cameraID: String?                // nil for display
      var isCamera: Bool
      var storage: (kind: String, id: String)      // ("display","3") / ("camera","<uid>")
      init?(kind: String, id: String)
      enum ResolveError: Equatable { case displayMissing, cameraMissing }
      /// Pure availability check used by arm() and the hotkey path.
      func resolve(cameraIDs: [String], displayIDs: [CGDirectDisplayID]) -> ResolveError?
  }
  enum RecorderSelection {
      static func frontCameraIDs(all: [String], main: MainSource) -> [String]        // all minus main camera
      static func resolvedFrontCamera(_ id: String?, candidates: [String]) -> String? // nil if absent
      static func systemAudioAllowed(for main: MainSource) -> Bool                   // false for .camera
      static func areaAllowed(for main: MainSource) -> Bool                          // false for .camera
      static func needsScreenPermission(for main: MainSource) -> Bool                // false for .camera
  }
  extension AppSettings {
      static var lastMainSource: MainSource?   // keys "lastMainSourceKind","lastMainSourceID"; nil → .display(lastDisplayID) if set
  }
  ```

- [ ] **Step 1: Failing tests**

```swift
@Test func storageRoundTrip() {
    let c = MainSource.camera(uniqueID: "abc")
    #expect(MainSource(kind: c.storage.kind, id: c.storage.id) == c)
    let d = MainSource.display(7)
    #expect(MainSource(kind: d.storage.kind, id: d.storage.id) == d)
    #expect(MainSource(kind: "display", id: "x") == nil)
}
@Test func resolveReportsMissingDevice() {
    #expect(MainSource.camera(uniqueID: "a").resolve(cameraIDs: ["b"], displayIDs: [1]) == .cameraMissing)
    #expect(MainSource.camera(uniqueID: "a").resolve(cameraIDs: ["a"], displayIDs: []) == nil)
    #expect(MainSource.display(2).resolve(cameraIDs: [], displayIDs: [1]) == .displayMissing)
}
@Test func frontExcludesMainCamera() {
    #expect(RecorderSelection.frontCameraIDs(all: ["a","b"], main: .camera(uniqueID: "a")) == ["b"])
    #expect(RecorderSelection.frontCameraIDs(all: ["a","b"], main: .display(1)) == ["a","b"])
}
@Test func resolvedFrontDropsConflict() {
    #expect(RecorderSelection.resolvedFrontCamera("a", candidates: ["b"]) == nil)
    #expect(RecorderSelection.resolvedFrontCamera("b", candidates: ["b"]) == "b")
}
@Test func cameraMainDisablesScreenOnlyOptions() {
    let cam = MainSource.camera(uniqueID: "a")
    #expect(!RecorderSelection.systemAudioAllowed(for: cam))
    #expect(!RecorderSelection.areaAllowed(for: cam))
    #expect(!RecorderSelection.needsScreenPermission(for: cam))
    #expect(RecorderSelection.areaAllowed(for: .display(1)))
    #expect(RecorderSelection.needsScreenPermission(for: .display(1)))
}
```

- [ ] **Step 2:** `swift test --filter MainSourceTests` → FAIL.
- [ ] **Step 3:** Implement. `lastMainSource` setter also writes `lastDisplayID` when `.display` so legacy readers stay in sync.
- [ ] **Step 4:** `swift test` → PASS.
- [ ] **Step 5:** Commit `feat(recorder): MainSource model, resolver and selection rules`.

### Task 8: Studio + Dashboard read via `mainTrack`

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift:655-740` (`makeComposition`), `:1434-1449` (auto-zoom), `:3080` (Reveal in Finder); `Sources/CaptureStudio/Studio/StudioWindow.swift:292` (zoom lane); `Sources/CaptureStudio/Dashboard/ThumbnailStore.swift:47-66`; `Sources/CaptureStudio/Dashboard/ProjectLibrary.swift:65-95`; `Sources/CaptureStudio/Dashboard/DashboardView.swift:341`
- Test: `Tests/CaptureStudioTests/ProjectLibraryTests.swift` (extend)

**Interfaces:**
- Consumes: `ProjectMeta.mainTrack`, `overlayCameraTrack`, `isCameraMain`, `ProjectBundle.url(for:)`.
- Produces: `ProjectSummary.isCameraMain: Bool`; `ProjectSummary.hasCamera` now means "has overlay camera".

- [ ] **Step 1: Failing test** in `ProjectLibraryTests`: write a bundle dir with meta whose tracks are `[main-camera.mp4 role main]` (schemaVersion 2, mainSource "camera") and an empty `main-camera.mp4`, no `screen.mp4`; `#expect(summary.status == .ready && summary.isCameraMain && !summary.hasCamera)`. Legacy meta with screen+camera → `isCameraMain == false && hasCamera`.
- [ ] **Step 2:** `swift test --filter ProjectLibraryTests` → FAIL.
- [ ] **Step 3:** `makeComposition`: `guard let mainInfo = meta.mainTrack` (error text "Bundle has no main video track."); load `bundle.url(for: mainInfo)`; offsets subtract `mainInfo.sessionStartHostTime`; overlay uses `meta.overlayCameraTrack` + `bundle.url(for:)`. Keep variable names `screenTrackID` etc. to limit churn.
- [ ] **Step 3b (Part C amendment):** honor `preferredTransform` for both video tracks: load `videoTrack.load(.preferredTransform)`, set `compTrack.preferredTransform`, and use `naturalSize.applying(transform)` (absolute width/height) for `renderSize` and `cameraSize`. Today the transform is ignored, so a portrait phone recording (Part C) would render sideways. Extend `StudioModelFitTests` with a 1920×1080 track + 90° transform → render size 1080×1920. Local screen/camera tracks have identity transforms, so no behavior change for existing bundles.
- [ ] **Step 4:** Gate on `hasCursorData`: `StudioWindow.swift:292` only builds the zoom lane when true; auto-zoom generation at `StudioModel.swift:1434-1449` early-returns when false. Reveal in Finder (`:3080`) selects `bundle.url(for: meta.mainTrack)` falling back to `bundle.url`.
- [ ] **Step 5:** `ThumbnailStore.generate`/`duration`: load meta, use `bundle.url(for: meta.mainTrack)`; fall back to `screenURL` if meta unreadable. Do not cache a `failed` entry when the meta is unreadable (a bundle mid-write).
- [ ] **Step 6:** `ProjectLibrary.summary`: `hasCamera = meta.overlayCameraTrack != nil`, `isCameraMain = meta.isCameraMain`. `DashboardView:341`: show a `video.fill` badge when `isCameraMain` next to the existing camera badge.
- [ ] **Step 7:** `grep -n "meta.display\|screenURL" Sources/CaptureStudio/Studio/*.swift Sources/CaptureStudio/Dashboard/*.swift` → only `loadOverlayData` (no-op without events) and the ThumbnailStore fallback remain.
- [ ] **Step 8:** `swift test` → PASS; `swift build` → OK.
- [ ] **Step 9:** Commit `feat(studio): open bundles whose main track is a camera`.

### Task 9: RecordingSession camera-main path

**Files:**
- Modify: `Sources/CaptureStudio/Recorder/RecordingSession.swift` — `arm` `:166-330`, `enterDragMode` `:378`, `buildDeferredScreenRecorder` `:438`, `beginRecording` `:503-540`, `cancelArming` `:549`, `toggleFromHotkey` `:565-587`, `toggle`/`startFromIdle` `:600-655`, `startCountdownThenBegin` `:658-690`, `cancelCountdownOrArming` `:694`, `tearDownArmed` `:705-740`, `stop` `:744-836`, `tearDownForQuit` `:874`; `Sources/CaptureStudio/App/CameraPreviewPanel.swift:22-45` (placement); `Sources/CaptureStudio/App/RecorderMenuView.swift` (minimal caller update only: pass `.display(selectedDisplayID)` — real UI lands in Task 10); `Sources/CaptureStudio/App/CaptureStudioApp.swift` (any `toggle(`/`arm(` caller)

**Interfaces:**
- Produces:
  ```swift
  func arm(main: MainSource, cameraID: String? = nil, micID: String? = nil, systemAudio: Bool = false,
           region: CGRect? = nil, previewControls: Bool = false, areaSelection: AreaSelection = .unavailable) async
  func toggle(main: MainSource?, cameraID: String?, micID: String?, systemAudio: Bool, region: CGRect? = nil,
              activateForPrompts: Bool, previewFirst: Bool = false, areaSelection: AreaSelection = .unavailable) async
  private var armedMain: MainSource?
  private var mainCameraRecorder: CameraRecorder?
  private var mainPreviewPanel: CameraPreviewPanel?
  ```
  `CameraPreviewPanel.init(session:onDisplay:placement:onCancel:)` with `enum Placement { case corner, bottomCenterLarge }` (large = 640×480, bottom-center, above the HUD's 24 pt bottom margin + HUD height so they don't overlap).
- Consumes: Task 3 `writtenPixelSize`, Task 4 `onDeviceLost`, Task 6 roles/URLs/`DisplayInfo.synthetic`, Task 7 `MainSource`, `resolve`, `RecorderSelection`.

- [ ] **Step 1:** Add the three stored properties. Every site that reads/writes `cameraRecorder` or `previewPanel` also handles `mainCameraRecorder` / `mainPreviewPanel`: `arm`, `beginRecording`, `stop` (`:765-772`, `:819-834`), `tearDownArmed` (detach block `:723-734` + `previewPanel?.close()` `:706`), `tearDownForQuit` (`:874+`). `armedMain` is set in `arm` and cleared wherever `armedDisplayID` is cleared.
- [ ] **Step 2:** `arm(main:)`:
  - `.display(id)`: existing body verbatim with `displayID = id`; `armedMain = main`.
  - `.camera(uid)`: skip `DeviceDiscovery.displays()` (needs screen permission). Resolve availability with `main.resolve(cameraIDs: availableCameraIDs(), displayIDs: [])` where `func availableCameraIDs() -> [String]` is a new single helper (today: `DeviceDiscovery.cameras().map(\.uniqueID)`; Part C appends phone ids). Missing → `state = .failed("Selected camera is no longer available.")`. Build the recorder through a `makeCameraSource(id:…)` factory (today: `CameraRecorder` from the matching `AVCaptureDevice`; Part C branches on the id prefix first). Create bundle. `mainCameraRecorder = CameraRecorder(device:, outputURL: bundle.mainCameraURL, micDevice:, micOutputURL:)`; `warmUp()` failure → `abandonArm(bundle)`, `.failed(error.localizedDescription)`. `mainPreviewPanel = CameraPreviewPanel(session:, onDisplay: nil, placement: .bottomCenterLarge, onCancel:)`. Overlay camera (only if `RecorderSelection.resolvedFrontCamera(cameraID, candidates: frontCameraIDs(...)) != nil`) → existing best-effort block, `micDevice: nil`, `placement: .corner`. Main mic warning → `warmUpStandaloneMic`. Set `displayInfo = nil`, `armedRegion = nil`, `armedDisplayID = nil`, `armedSystemAudio = false`, `armedAreaSelection = .unavailable`; HUD `offersAreaSelection: false`, `onDisplay: nil`. `screenRecorder` stays nil.
- [ ] **Step 3:** `startCountdownThenBegin` (`:666`): the `if screenRecorder == nil { buildDeferredScreenRecorder() }` rebuild runs **only when `armedMain?.isCamera == false`**. Without this every camera-main Record fails with "No area selected.". `buildDeferredScreenRecorder` and `enterDragMode` early-return (`return false` / no-op) when `armedMain?.isCamera == true`.
- [ ] **Step 4:** `beginRecording()`: guard becomes `guard isArmed, let bundle, let armedMain else`. Camera-main: `guard let mainCameraRecorder`; `try beginWriting()` failure → `tearDownArmed()`, `.failed`. Display: existing `screenRecorder.start()` block (guard `screenRecorder`/`displayInfo` non-nil inside this branch). **Both branches then run the existing overlay `cameraRecorder.beginWriting()` (`:522`) and `micRecorder.beginWriting()` (`:529`) blocks.** `eventTracker.start()` only in the display branch.
- [ ] **Step 5:** `stop()`: branch on `armedMain`. Camera: `let result = try await mainCameraRecorder.stop()`; main track = `result.camera` with `role = .main`; mic from `result.mic`; overlay from `cameraRecorder` with `role = .overlay`; standalone `micRecorder` as today; no events; `display = DisplayInfo.synthetic(width:height:)` from `mainCameraRecorder.writtenPixelSize` (fallback 1920×1080); `schemaVersion: 2`, `mainSource: "camera"`. Display: unchanged plus `mainSource: "display"`. The `.failed(...)` on `stop()` catch must still close `mainPreviewPanel`.
- [ ] **Step 6:** `startFromIdle(main:)`: `guard let main`. Permission gate becomes `if RecorderSelection.needsScreenPermission(for: main) { guard Permissions.screenRecordingGranted() else { return } }`. Request `.video` when `main.isCamera || camera != nil`; `.audio` when `mic != nil`. `willPreview = main.isCamera || camera != nil || previewFirst`; the fast path `if camera == nil, !previewFirst, isArmed { startCountdownThenBegin() }` becomes `if !main.isCamera, camera == nil, !previewFirst, isArmed`.
- [ ] **Step 7:** `toggleFromHotkey()` (uses `availableCameraIDs()` for the camera check): resolve `main` **first**: `let stored = AppSettings.lastMainSource`; if `stored?.isCamera == true` → `main = stored`, `region = nil`, `areaSelection = .unavailable`, skip the area early-return entirely. Else existing area logic with `main = area ? AppSettings.captureRegionDisplayID.map(MainSource.display) : stored`. `nil` main → return.
- [ ] **Step 8:** Update every `arm(displayID:` / `toggle(displayID:` caller (`grep -rn "toggle(displayID\|arm(displayID" Sources`) to pass `main: selectedDisplayID.map(MainSource.display)` for now.
- [ ] **Step 9:** `swift build` → OK; `swift test` → PASS (existing `ArmedRecordGateTests` unchanged).
- [ ] **Step 10:** Commit `feat(recorder): record a camera as the main track`.

### Task 10: Recorder popup — Main picker + Front camera picker + permission fork

**Files:**
- Modify: `Sources/CaptureStudio/App/RecorderMenuView.swift` — state `:8-30`, `.onChange` `:102-103`, `permissionView`/`recorderView` switch `:45-49`, pickers `:230-290`, Preview button `:330-360` (`.disabled` at `:357`), `displayLabel` `:579-582`, `recordingTargetSuffix` `:599-604`, `refreshDevices` `:607-629`

**Interfaces:**
- Consumes: `MainSource`, `RecorderSelection`, `AppSettings.lastMainSource`, `DeviceDiscovery.grouped`, Task 9 `toggle(main:)`.

- [ ] **Step 1:** Replace `selectedDisplayID` with `@State private var mainSource: MainSource?`. Update every reader listed above (`displayLabel`, `recordingTargetSuffix`, Preview `.disabled`, `refreshDevices` fallback) — `grep -n selectedDisplayID` must return zero hits when done.
- [ ] **Step 2:** The dropdown becomes "Main" and is **always rendered** (today it is hidden under `!captureAreaEnabled` at `:235`, which would make a camera main unreachable in Area mode). Sections: "Displays" (existing rows; hidden with an inline "Grant Screen Recording to record a display" row when `!permissionGranted`) and "Cameras" (grouped via Task 2). Area mode + display main keeps today's semantics (the picker is informational for area).
- [ ] **Step 3:** Camera picker relabeled "Front camera", rows filtered by `RecorderSelection.frontCameraIDs(all: session.availableCameraIDs(), main:)`; `selectedCameraID` passed through `resolvedFrontCamera` after every refresh and after a main change.
- [ ] **Step 4:** When `mainSource?.isCamera == true`: area toggle and system-audio toggle `.disabled(true)` with `.help("Not available when a camera is the main source")`; the Preview button passes `region: nil`, `systemAudio: false`, `areaSelection: .unavailable`.
- [ ] **Step 5:** Permission fork (spec B0): `body` shows `recorderView` whenever `permissionGranted || mainSource?.isCamera == true || !cameras.isEmpty`; `permissionView` content moves into the Displays section row. `refreshDevices` already enumerates cameras/mics without the permission (Task 5).
- [ ] **Step 6:** Persist `AppSettings.lastMainSource` in the Main `pickRow` actions (not `.onChange`).
- [ ] **Step 7:** `swift build` → OK; `swift test` → PASS.
- [ ] **Step 8:** Commit `feat(recorder): main source picker with front camera selection`.

### Task 11: End-to-end manual verification

**Files:** none (spec "Test hardware" section updated with results).

- [ ] **Step 1:** `scripts/build-app.sh debug; pkill -x CaptureStudio; open dist/CaptureStudio.app`.
- [ ] **Step 2:** Display main + phone front camera + phone/virtual mic → record 10 s → Studio: PiP shows phone, audio aligned.
- [ ] **Step 3:** Phone main + MacBook front camera + MacBook mic → record 10 s → Studio: canvas aspect matches phone, FaceTime PiP, Zoom inspector disabled and no zoom/cursor lane; export succeeds; Reveal in Finder works.
- [ ] **Step 4:** Repeat Step 3 but unplug the phone at 5 s → recording saves, warning "Camera disconnected.", main track `truncated: true` in `meta.json`.
- [ ] **Step 5:** Hotkey with phone main saved: first press arms + previews with HUD, second press records. Unplug, press hotkey → "Selected camera is no longer available.". Turn Area mode on with no saved area, phone main → hotkey still arms (area ignored).
- [ ] **Step 6:** Revoke Screen Recording in System Settings → popup still shows the recorder with cameras only; phone-main recording works; display rows show the grant hint.
- [ ] **Step 7:** Open a pre-feature bundle → identical behavior to before. Cancel from armed camera-main (Esc on preview) → bundle deleted, both panels closed.
- [ ] **Step 8:** Record findings in the spec; file follow-ups for anything that failed.
