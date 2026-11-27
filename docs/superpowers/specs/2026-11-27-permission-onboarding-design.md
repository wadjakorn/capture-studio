# Permission Onboarding & Capture-Issue Alerts — Design

Date: 2026-11-27. Status: user opted out of the Q&A round ("make the plan, then
scrutinize"); every decision below not quoted from the user is Claude's call.

## Intent

User request: give the app a permission onboarding, and alert the user when it lacks
the permissions it needs — screen, microphone, audio, and others — both when access is
missing and when a connection/device is lost.

Why (inferred, not stated): v0.3 ships to the public via Homebrew. Today a new user can
end up with a recording that silently lacks mic/camera, a hotkey that does nothing, or a
phone that is "not reachable" with no hint that a macOS permission is the cause.

## Current state (2026-11-27, `main` @ dc9fa3a)

- `Recorder/Permissions.swift`: screen preflight/request/open-settings + camera/mic
  `requestCapture`. No status model, no mic/camera/local-network settings links.
- Popup: `@State permissionGranted` read once (stale after granting in Settings);
  screen-permission block only when no camera/phone exists.
- Hotkey with no Screen Recording grant → silent no-op (`RecordingSession.swift:1086`).
- Camera/mic denied → source silently dropped, no warning (`:1098-1107`).
- Local Network denied → "Phone not reachable." only; `PhoneBrowser` ignores `.waiting`.
- Mid-session loss: `CameraRecorder` and `PhoneStreamRecorder` already report device
  loss into `session.warnings`; standalone `MicRecorder` observes nothing.
- Screen `SCStream` stop error → partial save + generic "capture stopped early" text,
  including when the user stopped sharing from the macOS menu bar.
- `session.warnings` / `.failed` are only visible inside the menu-bar popup; no toast
  surfaces them while the popup is closed (i.e. always while recording).

## Goals

1. First-run onboarding window listing Screen Recording (required for screen capture,
   covers system audio), Microphone, Camera, Local Network (phones) — status + one-click
   Allow / Open Settings / Relaunch.
2. Live permission status that refreshes when the app becomes active (user returns from
   System Settings).
3. Pre-record check: a missing permission that blocks the chosen setup fails visibly
   (popup row + toast), never silently — GUI and hotkey alike. A missing optional
   permission records anyway with a warning naming what will be missing.
4. Mid-session loss alerts: mic unplug/error, screen-capture stop (permission revoked,
   display gone, system stop), existing camera/phone loss — shown as a toast immediately,
   recording continues/saves as today.
5. Persistent hint: Dashboard banner while Screen Recording is off (mic/camera denial is
   a deliberate choice — covered per take by the preflight warning, not a banner).

## Non-goals

- Input Monitoring / Accessibility: keystroke events are captured but unused by Studio.
- System notifications (UNUserNotificationCenter): would add yet another permission;
  in-app toasts instead.
- Auto-reconnect of lost devices mid-take; warnings inside Studio; menu-bar icon badge.
- Changing `RecordingSession.warnings` from `[String]` to a structured type.
- Finalizing a take when the app quits mid-recording (pre-existing: `tearDownForQuit`
  drops it). Follow-up candidate; this work only gates its own Relaunch button on an
  idle/failed session.

## Anti-goals

- Nagging: onboarding shows once (or never for upgraders who already granted
  everything); toasts never stack or steal focus.
- Any new chrome window/panel appearing in `screen.mp4` (fail-closed allowlist must
  stay untouched: do not register them with `CaptureContentWindows`).
- Blocking a recording because of an *optional* permission.

## Constraints

- macOS 15+, Swift 6 language mode, CLT build must stay green, no new dependencies, no
  `#Preview`, no new entitlements (camera/mic already declared; ScreenCaptureKit and
  Bonjour need none in a non-sandboxed app; usage strings already in `Info.plist`).
- Screen Recording grant may only take effect after relaunch → offer Relaunch.
- Local Network has no query API → derive from `NWBrowser` `.waiting(.dns(PolicyDenied))`
  (denied) / a discovered phone (granted) / otherwise unknown.

## Approaches considered

1. **Central `PermissionCenter` + pure preflight rules + one toast notifier (chosen).**
   One observable status source feeds popup, onboarding, Dashboard banner and the
   session's start path; one notifier turns `warnings`/`.failed` into toasts. Small,
   testable pure cores; reuses the existing warnings pipeline.
2. Per-screen ad-hoc checks (patch each view/recorder). Less code up front, but status
   goes stale in each place independently — the bug the popup has today.
3. Structured `SessionIssue` type replacing `warnings: [String]`. Cleaner Fix-button
   mapping, but touches ~40 call sites in a 70 KB file for little user-visible gain;
   approach 1 maps the few permission messages back to a kind by exact-string lookup.

## Decided (Claude's calls)

- Onboarding shows at plain launch (not login-item, not document launch) when not yet
  completed **and** any of screen/mic/camera is not granted; closing or Done completes it.
  Reopenable from the popup footer ("Permissions…"), the Dashboard banner and toasts.
- Toasts: top-center non-activating panel, 8 s, hover pauses. Warning toasts are
  suppressed while the menu-bar popup is open (it lists them); failure toasts never are.
  Fix button when the issue maps to a permission; a Screen Recording Fix also brings up
  the onboarding window so Relaunch is one click away.
- User pressing "Stop" in the macOS screen-sharing menu = a normal stop, not a failure.
- Upgraders who already granted screen+mic+camera never see onboarding.

## Left to the builder

Visual details of rows/pills/banners within existing popup/Dashboard styling.
