# SRT Subtitle Time Offset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single signed time offset (seconds) to an imported SRT subtitle track so cue timings from a raw, untrimmed source can be re-synced to the trimmed Studio timeline.

**Architecture:** Store `offset` on `SubtitleTrack`; keep cues raw. A pure helper `SubtitleTimeline.effective(_:offset:duration:)` shifts + clamps cues at every consumption point (compositor, lane, canvas overlay) via a single `StudioModel.effectiveSubtitleCues` accessor. The offset is set live from a popover control and a "Set from playhead" button, previews immediately, persists, and survives re-import.

**Tech Stack:** Swift 6 (Command Line Tools toolchain), SwiftUI, Core Image compositor, swift-testing.

## Global Constraints

- **Toolchain: Command Line Tools only.** Do NOT bump swift-testing (`0.12.0` exact) or KeyboardShortcuts (`1.10.0` exact).
- `swift build` must stay warning-free; `swift test` must stay green (109+ tests). No deprecated APIs.
- `EditState.schemaVersion` stays `1`. New Codable fields are additive + forward-compatible: decode with `decodeIfPresent(...) ?? default` so legacy projects load clean.
- The offset is in **seconds**, added to every cue's `begin`/`end`. Negative = earlier, positive = later. It is NOT derived from `trimIn`.
- Stored cues remain **raw** (their original SRT times); the offset is applied only at consumption, never baked in.
- Cues stay read-only — no per-cue editing. One shared offset for the whole track, like the shared style.
- Commit messages end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Do not push; commits are local. (Branch is already `claude/recursing-brattain-1057af`.)

---

### Task 1: Add `offset` to `SubtitleTrack`

**Files:**
- Modify: `Sources/CaptureStudio/ProjectBundle/EditState.swift:347-365`
- Test: `Tests/CaptureStudioTests/EditStateTests.swift`

**Interfaces:**
- Consumes: existing `SubtitleTrack` (`srtFilename: String`, `style: SubtitleStyle`, `cues: [SubtitleCue]`).
- Produces: `SubtitleTrack.offset: Double` (default `0`); memberwise init `SubtitleTrack(srtFilename:style:cues:offset:)` with `offset: Double = 0` as the last parameter.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CaptureStudioTests/EditStateTests.swift` (inside the same `@Suite struct`):

```swift
    @Test func subtitleOffsetRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = SubtitleTrack(
            srtFilename: "subtitles.srt",
            cues: [SubtitleCue(begin: 1, end: 2, text: "Hi")],
            offset: -2.5)
        var edit = EditState()
        edit.subtitles = track
        try bundle.writeEdit(edit)
        #expect(bundle.loadEdit().subtitles?.offset == -2.5)
    }

    @Test func legacySubtitleTrackHasZeroOffset() throws {
        let json = #"{"srtFilename":"s.srt","style":{},"cues":[{"begin":1,"end":2,"text":"Hi"}]}"#
        let track = try JSONDecoder().decode(SubtitleTrack.self, from: Data(json.utf8))
        #expect(track.offset == 0)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter EditStateTests`
Expected: FAIL — `subtitleOffsetRoundTrips` fails to compile (`extra argument 'offset'`).

- [ ] **Step 3: Add the field**

In `Sources/CaptureStudio/ProjectBundle/EditState.swift`, change `SubtitleTrack` (lines 347-365) to:

```swift
struct SubtitleTrack: Codable, Equatable {
    var srtFilename: String
    var style: SubtitleStyle
    var cues: [SubtitleCue]
    var offset: Double           // seconds, added to every cue's begin/end (re-sync)

    init(srtFilename: String, style: SubtitleStyle = SubtitleStyle(),
         cues: [SubtitleCue] = [], offset: Double = 0) {
        self.srtFilename = srtFilename
        self.style = style
        self.cues = cues
        self.offset = offset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        srtFilename = try c.decodeIfPresent(String.self, forKey: .srtFilename) ?? ""
        style = try c.decodeIfPresent(SubtitleStyle.self, forKey: .style) ?? SubtitleStyle()
        cues = try c.decodeIfPresent([SubtitleCue].self, forKey: .cues) ?? []
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
    }
}
```

(`CodingKeys` is synthesized from the stored properties, so adding `offset` extends it automatically; the synthesized encoder writes it. No explicit `CodingKeys` enum exists to edit.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter EditStateTests`
Expected: PASS (including the existing `subtitlesRoundTrip`, which still passes because `offset` defaults to `0` and is `Equatable`).

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/ProjectBundle/EditState.swift Tests/CaptureStudioTests/EditStateTests.swift
git commit -m "feat: add offset field to SubtitleTrack

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `SubtitleTimeline.effective` (offset-aware shift + clamp)

**Files:**
- Modify: `Sources/CaptureStudio/Studio/SubtitleTimeline.swift:13-22` (replace `clamped`)
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift:359` and `:979` (migrate the two `clamped` call sites)
- Test: `Tests/CaptureStudioTests/SubtitleTimelineTests.swift`

**Interfaces:**
- Consumes: `SubtitleCue` (`begin: Double`, `end: Double`, `text: String`).
- Produces: `static func effective(_ cues: [SubtitleCue], offset: Double, duration: Double) -> [SubtitleCue]`. Replaces and removes `clamped(_:duration:)`. `effective(_, offset: 0, duration:)` reproduces the old `clamped` behavior exactly.

- [ ] **Step 1: Replace the `clamped` tests with `effective` tests**

In `Tests/CaptureStudioTests/SubtitleTimelineTests.swift`, delete the two `clamped*` tests (`clampedDropsPastDurationAndClampsEnd`, `clampedDropsCueStartingAtDuration`) and add:

```swift
    @Test func effectiveOffsetZeroMatchesOldClamp() {
        let c = [cue(1, 5, "keep"), cue(8, 12, "clamp"), cue(20, 22, "drop")]
        let out = SubtitleTimeline.effective(c, offset: 0, duration: 10)
        #expect(out.count == 2)
        #expect(out[0].text == "keep" && out[0].end == 5)
        #expect(out[1].text == "clamp" && out[1].end == 10)   // clamped to duration
    }

    @Test func effectiveDropsCueStartingAtDuration() {
        #expect(SubtitleTimeline.effective([cue(10, 11)], offset: 0, duration: 10).isEmpty)
    }

    @Test func effectivePositiveOffsetShiftsLater() {
        let out = SubtitleTimeline.effective([cue(1, 2)], offset: 3, duration: 10)
        #expect(out.count == 1 && out[0].begin == 4 && out[0].end == 5)
    }

    @Test func effectiveNegativeOffsetShiftsEarlier() {
        let out = SubtitleTimeline.effective([cue(5, 6)], offset: -3, duration: 10)
        #expect(out.count == 1 && out[0].begin == 2 && out[0].end == 3)
    }

    @Test func effectiveDropsCueShiftedPastEnd() {
        #expect(SubtitleTimeline.effective([cue(8, 9)], offset: 5, duration: 10).isEmpty)
    }

    @Test func effectiveDropsCueShiftedBeforeZero() {
        #expect(SubtitleTimeline.effective([cue(1, 2)], offset: -5, duration: 10).isEmpty)
    }

    @Test func effectiveClampsBeginAtZero() {
        let out = SubtitleTimeline.effective([cue(1, 4)], offset: -2, duration: 10)
        #expect(out.count == 1 && out[0].begin == 0 && out[0].end == 2)
    }

    @Test func effectiveClampsEndAtDuration() {
        let out = SubtitleTimeline.effective([cue(7, 11)], offset: 1, duration: 10)
        #expect(out.count == 1 && out[0].begin == 8 && out[0].end == 10)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SubtitleTimelineTests`
Expected: FAIL — `effective` does not exist (compile error).

- [ ] **Step 3: Replace `clamped` with `effective`**

In `Sources/CaptureStudio/Studio/SubtitleTimeline.swift`, replace the `clamped` function (lines 13-22) with:

```swift
    /// Shift every cue by `offset` seconds, then drop cues that fall entirely
    /// outside `[0, duration)` and clamp the survivors to that range. Preserves
    /// order. `offset == 0` reproduces the previous `clamped` behavior.
    static func effective(_ cues: [SubtitleCue], offset: Double, duration: Double) -> [SubtitleCue] {
        cues.compactMap { cue in
            let begin = cue.begin + offset
            let end = cue.end + offset
            guard end > 0, begin < duration else { return nil }
            var c = cue
            c.begin = max(0, begin)
            c.end = min(end, duration)
            return c
        }
    }
```

- [ ] **Step 4: Migrate the two call sites (no behavior change — offset 0)**

In `Sources/CaptureStudio/Studio/StudioModel.swift` line 359, change:

```swift
                let cues = SubtitleTimeline.clamped(track.cues, duration: duration)
```
to:
```swift
                let cues = SubtitleTimeline.effective(track.cues, offset: 0, duration: duration)
```

And line 979, change:

```swift
                let cues = SubtitleTimeline.clamped(SubtitleParser.parse(raw), duration: duration)
```
to:
```swift
                let cues = SubtitleTimeline.effective(SubtitleParser.parse(raw), offset: 0, duration: duration)
```

(Task 3 rewires these to use the stored offset and raw cues; this step only keeps the build green with identical behavior.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift build && swift test --filter SubtitleTimelineTests`
Expected: `swift build` succeeds with no warnings; tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/Studio/SubtitleTimeline.swift Sources/CaptureStudio/Studio/StudioModel.swift Tests/CaptureStudioTests/SubtitleTimelineTests.swift
git commit -m "feat: replace subtitle clamped with offset-aware effective

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Store raw cues + apply offset at every consumer

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` — `:110-114` (add accessor), `:358-363` (load), `:961-983` (import), `:1523-1525` (compositor)
- Modify: `Sources/CaptureStudio/Studio/SubtitleTimelineLane.swift:17`
- Modify: `Sources/CaptureStudio/Studio/SubtitleCanvasOverlay.swift:51-54`

**Interfaces:**
- Consumes: `SubtitleTimeline.effective(_:offset:duration:)` (Task 2), `SubtitleTrack.offset` (Task 1).
- Produces: `StudioModel.effectiveSubtitleCues: [SubtitleCue]` — the offset-shifted, duration-clamped cues that actually render. All three cue consumers read it.

This is integration glue (no new unit test — capture/UI glue is not unit-tested per project convention). Its deliverable is verified by `swift build` + the full suite staying green; with the default `offset == 0` and raw cues stored, rendered behavior is identical to before.

- [ ] **Step 1: Add the `effectiveSubtitleCues` accessor**

In `Sources/CaptureStudio/Studio/StudioModel.swift`, immediately after the `showsSubtitleTimeline` computed property (after line 114), add:

```swift
    /// Cues shifted by the track offset and clamped to the clip — exactly what
    /// renders. Empty when there is no track or every cue falls outside the clip.
    var effectiveSubtitleCues: [SubtitleCue] {
        guard let s = subtitles else { return [] }
        return SubtitleTimeline.effective(s.cues, offset: s.offset, duration: duration)
    }
```

- [ ] **Step 2: Store raw cues + offset in `load()`**

Replace lines 358-363 (the `if let track = edit.subtitles { ... }` block) with:

```swift
            // Keep cues raw; the offset is applied at consumption. A track whose
            // cues all fall outside the clip (after offset) loads as no subtitles
            // (the .srt file is left in the bundle).
            if let track = edit.subtitles {
                let surviving = SubtitleTimeline.effective(track.cues, offset: track.offset,
                                                           duration: duration)
                subtitles = surviving.isEmpty ? nil
                    : SubtitleTrack(srtFilename: track.srtFilename, style: track.style,
                                    cues: track.cues, offset: track.offset)
            }
```

- [ ] **Step 3: Capture the existing offset before the import task**

In `importSubtitles(from:)`, after line 966 (`let existingStyle = subtitles?.style`), add:

```swift
        let existingOffset = subtitles?.offset ?? 0
```

- [ ] **Step 4: Store raw cues + preserved offset in `importSubtitles`**

Replace the detached body's cue-build + return (lines 979-982) with:

```swift
                let parsed = SubtitleParser.parse(raw)
                guard !SubtitleTimeline.effective(parsed, offset: existingOffset,
                                                  duration: duration).isEmpty else { return nil }
                return SubtitleTrack(srtFilename: name,
                                     style: existingStyle ?? SubtitleStyle(),
                                     cues: parsed, offset: existingOffset)
```

- [ ] **Step 5: Feed effective cues to the compositor**

Replace the compositor block (lines 1523-1525) with:

```swift
        if let track = subtitles, !draggingSubtitle {
            let cues = effectiveSubtitleCues
            if !cues.isEmpty {
                layout.subtitles = SubtitleTimelineSpec(style: track.style, cues: cues)
            }
        }
```

- [ ] **Step 6: Read effective cues in the lane**

In `Sources/CaptureStudio/Studio/SubtitleTimelineLane.swift`, change line 17:

```swift
    private var cues: [SubtitleCue] { model.subtitles?.cues ?? [] }
```
to:
```swift
    private var cues: [SubtitleCue] { model.effectiveSubtitleCues }
```

- [ ] **Step 7: Read effective cues in the canvas overlay**

In `Sources/CaptureStudio/Studio/SubtitleCanvasOverlay.swift`, change `activeCue` (lines 51-54):

```swift
    private var activeCue: SubtitleCue? {
        guard let cues = model.subtitles?.cues else { return nil }
        return cues.first { $0.begin <= model.currentTime && model.currentTime < $0.end }
    }
```
to:
```swift
    private var activeCue: SubtitleCue? {
        model.effectiveSubtitleCues.first {
            $0.begin <= model.currentTime && model.currentTime < $0.end
        }
    }
```

- [ ] **Step 8: Build + run the full suite**

Run: `swift build && swift test`
Expected: `swift build` succeeds with no warnings; all tests PASS (the existing 109+ plus the new offset/effective tests). Behavior with `offset == 0` is unchanged.

- [ ] **Step 9: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift Sources/CaptureStudio/Studio/SubtitleTimelineLane.swift Sources/CaptureStudio/Studio/SubtitleCanvasOverlay.swift
git commit -m "feat: store raw subtitle cues, apply offset at consumers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Offset setters + popover control

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` — after line 1053 (`setSubtitleShadow`)
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift:741-822` (`subtitleStylePopover`)

**Interfaces:**
- Consumes: `applyVideoComposition()`, `saveEdit()`, `currentTime`, `subtitles` (with `.offset`, `.cues`).
- Produces: `func setSubtitleOffset(_ seconds: Double)` and `func setSubtitleOffsetFromPlayhead()` on `StudioModel`, driven by the popover.

This task is model + SwiftUI glue (not unit-tested, per convention); its deliverable is verified by `swift build` staying green and the interactive smoke test.

- [ ] **Step 1: Add the offset setters**

In `Sources/CaptureStudio/Studio/StudioModel.swift`, after `setSubtitleShadow` (line 1053), add:

```swift
    /// Shift every cue by `seconds` (added to begin/end). Clamped to a finite
    /// guard range — intentionally NOT tied to `duration`, so a begin-trim larger
    /// than the trimmed clip can still be corrected. Recomposites + saves.
    func setSubtitleOffset(_ seconds: Double) {
        guard subtitles != nil else { return }
        subtitles!.offset = min(max(-86_400, seconds), 86_400)
        applyVideoComposition()
        saveEdit()
    }

    /// Align cue #1 (the smallest raw `begin`) to the current playhead.
    func setSubtitleOffsetFromPlayhead() {
        guard let cues = subtitles?.cues, let minBegin = cues.map(\.begin).min() else { return }
        setSubtitleOffset(currentTime - minBegin)
    }
```

- [ ] **Step 2: Add the offset control to the popover**

In `Sources/CaptureStudio/Studio/StudioWindow.swift`, in `subtitleStylePopover`, insert the offset block immediately after the existing `Divider()` on line 747 (i.e., between that divider and the `Picker("Font", …)`):

```swift
                VStack(alignment: .leading, spacing: 4) {
                    Text("Time offset (s)").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("", value: Binding(
                            get: { model.subtitles?.offset ?? 0 },
                            set: { model.setSubtitleOffset($0) }
                        ), format: .number.precision(.fractionLength(2)))
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                        Stepper("", value: Binding(
                            get: { model.subtitles?.offset ?? 0 },
                            set: { model.setSubtitleOffset($0) }
                        ), in: -86_400...86_400, step: 0.1)
                            .labelsHidden()
                        Spacer()
                        Button("Set from playhead") { model.setSubtitleOffsetFromPlayhead() }
                            .controlSize(.small)
                    }
                    Text("SRT made from the raw (untrimmed) video? Nudge or set from the playhead to re-sync.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .disabled(model.subtitleState != .idle)

                Divider()
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds with no warnings.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all tests PASS (no new tests — UI glue; the pure offset math is already covered by Task 2).

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "feat: subtitle time-offset control + set-from-playhead

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Manual smoke test (interactive — run by the user)**

```bash
scripts/build-app.sh debug && pkill -x CaptureStudio; open dist/CaptureStudio.app
```

Open a recording in Studio, import an `.srt`, then verify:
1. The subtitle config popover shows a "Time offset (s)" field + stepper + "Set from playhead".
2. Typing a value (e.g. `-2.0`) and pressing Enter shifts every cue earlier; the canvas + lane update live.
3. The stepper nudges by 0.1 s.
4. Scrub to where cue #1 should start, click "Set from playhead" → cue #1 snaps to the playhead.
5. A large negative offset that pushes all cues off-screen leaves the lane empty but the popover reachable (recoverable).
6. Close + reopen the project → the offset persists.
7. Re-import the `.srt` → the offset (and style) is preserved.
8. Export → subtitles burn in at the offset position.

---

## Notes for the executor

- Line numbers are from the current `claude/recursing-brattain-1057af` checkout; if a prior task shifted them, match on the quoted code instead.
- Keep stored cues raw at all times — the only place the offset is applied is `SubtitleTimeline.effective`, reached through `effectiveSubtitleCues`.
- Do not introduce deprecated APIs (the build must stay warning-free).
