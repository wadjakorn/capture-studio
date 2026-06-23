# SRT Subtitle Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import an `.srt` file into a Capture Studio project to overlay read-only subtitles with one shared, one-time style/position/size config in a dedicated timeline lane.

**Architecture:** A new `SubtitleTrack` (shared `SubtitleStyle` + lightweight `SubtitleCue[]` + the bundled `.srt` filename) lives on `EditState.subtitles`. The compositor synthesizes a transient `TextBlock` from `style + cue` at each active cue and renders it through the existing `TextImageRenderer`/`textCache` path, beneath the manual text blocks. Cues are read-only; the user configures the shared style/position once. A loader gates import and remove.

**Tech Stack:** Swift 6 toolchain (Command Line Tools only), SwiftUI, AVFoundation, Core Image, swift-testing.

## Global Constraints

- **Toolchain: Command Line Tools only — no Xcode.app.** Do not bump swift-testing (`0.12.0` exact) or KeyboardShortcuts (`1.10.0` exact).
- Build with `swift build`; test with `swift test`. Keep all tests green (currently 109).
- Target macOS 15+. Bundle id `dev.wadjakorn.capture-studio` is stable.
- **`DisplayInfo` schema never changes.** `EditState.schemaVersion` stays `1` (the new field is additive + optional, no migration).
- Tests cover **pure helpers only** (parser, cue math, data model, bundle IO). Capture/UI/compositor glue is **not** unit-tested — those tasks verify with `swift build` and a final manual smoke test, per project convention.
- Commit messages in normal English, ending with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Never push.** Commits are local; the user pushes.
- Coordinate spaces: subtitle position is normalized 0–1 in render space (top-left origin), same as `TextBlock`. `fontSize` is a fraction of canvas height.

---

## File Structure

**Created:**
- `Sources/CaptureStudio/Studio/SubtitleParser.swift` — SRT text → `[SubtitleCue]` (pure).
- `Sources/CaptureStudio/Studio/SubtitleTimeline.swift` — active-cue / clamp / sub-row math (pure).
- `Sources/CaptureStudio/Studio/SubtitleTimelineLane.swift` — read-only lane UI.
- `Sources/CaptureStudio/Studio/SubtitleCanvasOverlay.swift` — draggable position box.
- `Tests/CaptureStudioTests/SubtitleParserTests.swift`
- `Tests/CaptureStudioTests/SubtitleTimelineTests.swift`

**Modified:**
- `Sources/CaptureStudio/ProjectBundle/EditState.swift` — `SubtitleStyle`/`SubtitleCue`/`SubtitleTrack` types, `EditState.subtitles`, `asTextBlock`.
- `Sources/CaptureStudio/ProjectBundle/ProjectBundle.swift` — bundle `.srt` read/write/delete.
- `Sources/CaptureStudio/Studio/CameraCompositor.swift` — `SubtitleTimelineSpec`, `CompositorLayout.subtitles`, render loop.
- `Sources/CaptureStudio/Studio/StudioModel.swift` — state, persistence, import/remove, style setters, selection, drag, compositor plumbing.
- `Sources/CaptureStudio/Studio/StudioWindow.swift` — import button, style popover, lane mount, canvas overlay, loader.
- `Tests/CaptureStudioTests/EditStateTests.swift` — subtitle round-trip + legacy decode.
- `Tests/CaptureStudioTests/ProjectBundleTests.swift` — subtitle file IO.

---

## Task 1: Subtitle data model, Codable, `asTextBlock`

**Files:**
- Modify: `Sources/CaptureStudio/ProjectBundle/EditState.swift` (add types after `TextBlock`, line ~239; extend `EditState` init + decoder)
- Test: `Tests/CaptureStudioTests/EditStateTests.swift`

**Interfaces:**
- Consumes: existing `TextWeight`, `TextAlignmentH`, `TextBlock`, `EditState`.
- Produces:
  - `struct SubtitleStyle: Codable, Equatable` with vars `centerX, centerY: Double`, `fontName: String`, `fontSize: Double`, `fontWeight: TextWeight`, `colorHex: String`, `alignment: TextAlignmentH`, `strokeWidth: Double`, `strokeHex: String`, `boxEnabled: Bool`, `boxHex: String`, `boxOpacity: Double`, `shadow: Bool`; memberwise init with defaults; `func asTextBlock(id: UUID, begin: Double, end: Double, text: String) -> TextBlock`.
  - `struct SubtitleCue: Codable, Equatable, Identifiable` with `id: UUID`, `begin, end: Double`, `text: String`.
  - `struct SubtitleTrack: Codable, Equatable` with `srtFilename: String`, `style: SubtitleStyle`, `cues: [SubtitleCue]`.
  - `EditState.subtitles: SubtitleTrack?` (default nil).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CaptureStudioTests/EditStateTests.swift` inside the `EditStateTests` suite:

```swift
    @Test func subtitlesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = SubtitleTrack(
            srtFilename: "subtitles.srt",
            style: SubtitleStyle(centerY: 0.8, fontSize: 0.07, colorHex: "#FFEE00"),
            cues: [SubtitleCue(begin: 1, end: 2.5, text: "Hello"),
                   SubtitleCue(begin: 3, end: 4, text: "World")])
        var edit = EditState()
        edit.subtitles = track
        try bundle.writeEdit(edit)
        #expect(bundle.loadEdit().subtitles == track)
    }

    @Test func legacyEditJSONHasNilSubtitles() throws {
        let json = #"{"schemaVersion":1,"trimIn":0}"#
        let edit = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(edit.subtitles == nil)
    }

    @Test func subtitleStyleMapsToTextBlock() {
        let style = SubtitleStyle(centerX: 0.4, centerY: 0.7, fontName: "Georgia",
                                  fontSize: 0.08, fontWeight: .bold, colorHex: "#112233",
                                  alignment: .leading, strokeWidth: 0.05, strokeHex: "#445566",
                                  boxEnabled: true, boxHex: "#778899", boxOpacity: 0.6,
                                  shadow: false)
        let id = UUID()
        let b = style.asTextBlock(id: id, begin: 1, end: 2, text: "Hi")
        #expect(b.id == id)
        #expect(b.begin == 1 && b.end == 2 && b.text == "Hi")
        #expect(b.centerX == 0.4 && b.centerY == 0.7)
        #expect(b.fontName == "Georgia" && b.fontSize == 0.08 && b.fontWeight == .bold)
        #expect(b.colorHex == "#112233" && b.alignment == .leading)
        #expect(b.strokeWidth == 0.05 && b.strokeHex == "#445566")
        #expect(b.boxEnabled && b.boxHex == "#778899" && b.boxOpacity == 0.6)
        #expect(b.shadow == false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EditStateTests`
Expected: FAIL — `SubtitleTrack`, `SubtitleStyle`, `SubtitleCue`, `edit.subtitles` not found.

- [ ] **Step 3: Add the new types**

In `Sources/CaptureStudio/ProjectBundle/EditState.swift`, after the closing brace of `TextBlock` (line ~239) and before `struct EditState` (line ~241), insert:

```swift
/// One subtitle cue parsed from an `.srt`: a `[begin, end)` span and read-only
/// text. Unlike `TextBlock`, a cue carries no style — the whole subtitle track
/// shares one `SubtitleStyle`.
struct SubtitleCue: Codable, Equatable, Identifiable {
    var id: UUID
    var begin: Double
    var end: Double
    var text: String

    init(id: UUID = UUID(), begin: Double, end: Double, text: String) {
        self.id = id
        self.begin = begin
        self.end = end
        self.text = text
    }
}

/// The one shared, user-configured look for every subtitle cue. Fields mirror
/// `TextBlock` styling so the existing `TextImageRenderer` renders cues unchanged
/// via `asTextBlock`. Position is normalized 0–1 in render space (top-left
/// origin); `fontSize` is a fraction of canvas height.
struct SubtitleStyle: Codable, Equatable {
    var centerX: Double
    var centerY: Double
    var fontName: String
    var fontSize: Double
    var fontWeight: TextWeight
    var colorHex: String
    var alignment: TextAlignmentH
    var strokeWidth: Double
    var strokeHex: String
    var boxEnabled: Bool
    var boxHex: String
    var boxOpacity: Double
    var shadow: Bool

    init(centerX: Double = 0.5, centerY: Double = 0.85,
         fontName: String = "Helvetica", fontSize: Double = 0.05,
         fontWeight: TextWeight = .semibold, colorHex: String = "#FFFFFF",
         alignment: TextAlignmentH = .center, strokeWidth: Double = 0,
         strokeHex: String = "#000000", boxEnabled: Bool = false,
         boxHex: String = "#000000", boxOpacity: Double = 0.5,
         shadow: Bool = true) {
        self.centerX = centerX
        self.centerY = centerY
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.colorHex = colorHex
        self.alignment = alignment
        self.strokeWidth = strokeWidth
        self.strokeHex = strokeHex
        self.boxEnabled = boxEnabled
        self.boxHex = boxHex
        self.boxOpacity = boxOpacity
        self.shadow = shadow
    }

    // Custom decode so a track written by an older/newer in-between version with
    // a missing field still loads, mirroring TextBlock / EditState.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.85
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0.05
        let weightRaw = try c.decodeIfPresent(String.self, forKey: .fontWeight)
        fontWeight = weightRaw.flatMap(TextWeight.init(rawValue:)) ?? .semibold
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
        let alignRaw = try c.decodeIfPresent(String.self, forKey: .alignment)
        alignment = alignRaw.flatMap(TextAlignmentH.init(rawValue:)) ?? .center
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0
        strokeHex = try c.decodeIfPresent(String.self, forKey: .strokeHex) ?? "#000000"
        boxEnabled = try c.decodeIfPresent(Bool.self, forKey: .boxEnabled) ?? false
        boxHex = try c.decodeIfPresent(String.self, forKey: .boxHex) ?? "#000000"
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? 0.5
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
    }

    /// Synthesize a transient `TextBlock` for one cue so the existing renderer /
    /// compositor text path draws it unchanged. `source` is `.manual` (cues are
    /// never auto-captions).
    func asTextBlock(id: UUID, begin: Double, end: Double, text: String) -> TextBlock {
        TextBlock(id: id, begin: begin, end: end, text: text,
                  centerX: centerX, centerY: centerY,
                  fontName: fontName, fontSize: fontSize, fontWeight: fontWeight,
                  colorHex: colorHex, alignment: alignment, boxEnabled: boxEnabled,
                  boxHex: boxHex, boxOpacity: boxOpacity, strokeWidth: strokeWidth,
                  strokeHex: strokeHex, shadow: shadow, source: .manual)
    }
}

/// An imported subtitle track: the bundled `.srt` filename, the one shared style,
/// and the read-only cues. Persisted on `EditState`; nil = no subtitles.
struct SubtitleTrack: Codable, Equatable {
    var srtFilename: String
    var style: SubtitleStyle
    var cues: [SubtitleCue]

    init(srtFilename: String, style: SubtitleStyle = SubtitleStyle(),
         cues: [SubtitleCue] = []) {
        self.srtFilename = srtFilename
        self.style = style
        self.cues = cues
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        srtFilename = try c.decodeIfPresent(String.self, forKey: .srtFilename) ?? ""
        style = try c.decodeIfPresent(SubtitleStyle.self, forKey: .style) ?? SubtitleStyle()
        cues = try c.decodeIfPresent([SubtitleCue].self, forKey: .cues) ?? []
    }
}
```

- [ ] **Step 4: Add the `subtitles` field to `EditState`**

In `EditState` (EditState.swift), after the `textBlocks` stored property (line ~308) add:

```swift
    /// Imported subtitle track (nil = none). Cues are read-only; `style` is the
    /// shared look. The `.srt` itself lives in the bundle (see ProjectBundle).
    var subtitles: SubtitleTrack? = nil
```

In the memberwise `init`, add a final parameter (after `textBlocks: [TextBlock] = []`) and assignment. Change the init signature's last line from:

```swift
         cameraBlocks: [CameraBlock] = [], textBlocks: [TextBlock] = []) {
```

to:

```swift
         cameraBlocks: [CameraBlock] = [], textBlocks: [TextBlock] = [],
         subtitles: SubtitleTrack? = nil) {
```

and after `self.textBlocks = textBlocks` (line ~356) add:

```swift
        self.subtitles = subtitles
```

In `init(from decoder:)`, after the `textBlocks = ...` line (line ~398) add:

```swift
        subtitles = try c.decodeIfPresent(SubtitleTrack.self, forKey: .subtitles)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter EditStateTests`
Expected: PASS (including the three new tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/CaptureStudio/ProjectBundle/EditState.swift Tests/CaptureStudioTests/EditStateTests.swift
git commit -m "feat: add SubtitleStyle/Cue/Track model and EditState.subtitles

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: SRT parser

**Files:**
- Create: `Sources/CaptureStudio/Studio/SubtitleParser.swift`
- Test: `Tests/CaptureStudioTests/SubtitleParserTests.swift`

**Interfaces:**
- Consumes: `SubtitleCue` (Task 1).
- Produces: `enum SubtitleParser { static func parse(_ raw: String) -> [SubtitleCue] }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CaptureStudioTests/SubtitleParserTests.swift`:

```swift
import Testing
import Foundation
@testable import CaptureStudio

@Suite struct SubtitleParserTests {
    @Test func wellFormedTwoCues() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,500
        Hello

        2
        00:00:03,000 --> 00:00:04,000
        World
        """
        let cues = SubtitleParser.parse(srt)
        #expect(cues.count == 2)
        #expect(cues[0].begin == 1.0 && cues[0].end == 2.5 && cues[0].text == "Hello")
        #expect(cues[1].begin == 3.0 && cues[1].end == 4.0 && cues[1].text == "World")
    }

    @Test func multiLineTextJoinedWithNewline() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,000
        Line one
        Line two
        """
        let cues = SubtitleParser.parse(srt)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Line one\nLine two")
    }

    @Test func crlfLineEndings() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHi\r\n"
        let cues = SubtitleParser.parse(srt)
        #expect(cues.count == 1 && cues[0].text == "Hi")
    }

    @Test func leadingBOMStripped() {
        let srt = "\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nHi"
        let cues = SubtitleParser.parse(srt)
        #expect(cues.count == 1 && cues[0].begin == 1.0)
    }

    @Test func missingIndexLineAccepted() {
        let srt = "00:00:01,000 --> 00:00:02,000\nNo index"
        let cues = SubtitleParser.parse(srt)
        #expect(cues.count == 1 && cues[0].text == "No index")
    }

    @Test func malformedBlockSkipped() {
        let srt = """
        1
        not a timestamp
        Skip me

        2
        00:00:05,000 --> 00:00:06,000
        Keep me
        """
        let cues = SubtitleParser.parse(srt)
        #expect(cues.count == 1 && cues[0].text == "Keep me")
    }

    @Test func emptyInputYieldsNoCues() {
        #expect(SubtitleParser.parse("").isEmpty)
        #expect(SubtitleParser.parse("\n\n  \n").isEmpty)
    }

    @Test func inlineTagsStripped() {
        let srt = "00:00:01,000 --> 00:00:02,000\n<i>Italic</i> and <b>bold</b>"
        let cues = SubtitleParser.parse(srt)
        #expect(cues.count == 1 && cues[0].text == "Italic and bold")
    }

    @Test func hourMinuteSecondsParsed() {
        let srt = "01:02:03,250 --> 01:02:04,000\nX"
        let cues = SubtitleParser.parse(srt)
        #expect(cues.count == 1)
        #expect(cues[0].begin == 3723.25 && cues[0].end == 3724.0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SubtitleParserTests`
Expected: FAIL — `SubtitleParser` not found.

- [ ] **Step 3: Write the parser**

Create `Sources/CaptureStudio/Studio/SubtitleParser.swift`:

```swift
import Foundation

/// Parses SubRip (`.srt`) text into timed cues. Pure + unit-tested, no file IO.
/// Tolerant: normalizes CRLF, strips a leading BOM, accepts blocks with or
/// without the leading index line, joins multi-line cue text with "\n", strips
/// simple `<i>`/`<b>`/`<u>` inline tags, and skips any block whose timestamp line
/// can't be parsed.
enum SubtitleParser {
    static func parse(_ raw: String) -> [SubtitleCue] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Strip a leading BOM if present.
        let text = normalized.hasPrefix("\u{FEFF}")
            ? String(normalized.dropFirst()) : normalized

        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            var lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            while let first = lines.first, first.isEmpty { lines.removeFirst() }
            guard !lines.isEmpty else { continue }
            // Optional index line: drop a leading line that isn't the timestamp.
            if !lines[0].contains("-->") { lines.removeFirst() }
            guard let timeLine = lines.first, timeLine.contains("-->"),
                  let times = parseTimes(timeLine) else { continue }
            let textLines = Array(lines.dropFirst()).filter { !$0.isEmpty }
            let cueText = stripTags(textLines.joined(separator: "\n"))
            cues.append(SubtitleCue(begin: times.begin, end: times.end, text: cueText))
        }
        return cues
    }

    /// "HH:MM:SS,mmm --> HH:MM:SS,mmm" → seconds pair, or nil.
    private static func parseTimes(_ line: String) -> (begin: Double, end: Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let b = seconds(parts[0]), let e = seconds(parts[1]) else { return nil }
        return (b, e)
    }

    /// "HH:MM:SS,mmm" (comma or dot decimal) → seconds.
    private static func seconds(_ stamp: String) -> Double? {
        let s = stamp.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let hms = s.components(separatedBy: ":")
        guard hms.count == 3,
              let h = Double(hms[0]), let m = Double(hms[1]), let sec = Double(hms[2])
        else { return nil }
        return h * 3600 + m * 60 + sec
    }

    private static func stripTags(_ s: String) -> String {
        ["<i>", "</i>", "<b>", "</b>", "<u>", "</u>"].reduce(s) {
            $0.replacingOccurrences(of: $1, with: "", options: .caseInsensitive)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SubtitleParserTests`
Expected: PASS (all 9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/SubtitleParser.swift Tests/CaptureStudioTests/SubtitleParserTests.swift
git commit -m "feat: add SRT parser (SubtitleParser)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Subtitle cue math (`SubtitleTimeline`)

**Files:**
- Create: `Sources/CaptureStudio/Studio/SubtitleTimeline.swift`
- Test: `Tests/CaptureStudioTests/SubtitleTimelineTests.swift`

**Interfaces:**
- Consumes: `SubtitleCue` (Task 1).
- Produces: `enum SubtitleTimeline` with `static func active(at t: Double, cues: [SubtitleCue]) -> [SubtitleCue]`, `static func clamped(_ cues: [SubtitleCue], duration: Double) -> [SubtitleCue]`, `static func subRows(_ cues: [SubtitleCue]) -> [[SubtitleCue]]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CaptureStudioTests/SubtitleTimelineTests.swift`:

```swift
import Testing
import Foundation
@testable import CaptureStudio

@Suite struct SubtitleTimelineTests {
    private func cue(_ begin: Double, _ end: Double, _ text: String = "") -> SubtitleCue {
        SubtitleCue(begin: begin, end: end, text: text)
    }

    @Test func activeIsHalfOpen() {
        let c = [cue(2, 4)]
        #expect(SubtitleTimeline.active(at: 1.99, cues: c).isEmpty)
        #expect(SubtitleTimeline.active(at: 2, cues: c).count == 1)
        #expect(SubtitleTimeline.active(at: 3.99, cues: c).count == 1)
        #expect(SubtitleTimeline.active(at: 4, cues: c).isEmpty)
    }

    @Test func clampedDropsPastDurationAndClampsEnd() {
        let c = [cue(1, 5, "keep"), cue(8, 12, "clamp"), cue(20, 22, "drop")]
        let out = SubtitleTimeline.clamped(c, duration: 10)
        #expect(out.count == 2)
        #expect(out[0].text == "keep" && out[0].end == 5)
        #expect(out[1].text == "clamp" && out[1].end == 10)   // clamped to duration
    }

    @Test func clampedDropsCueStartingAtDuration() {
        #expect(SubtitleTimeline.clamped([cue(10, 11)], duration: 10).isEmpty)
    }

    @Test func subRowsSingleRowWhenNoOverlap() {
        let rows = SubtitleTimeline.subRows([cue(0, 1), cue(1, 2), cue(2, 3)])
        #expect(rows.count == 1 && rows[0].count == 3)
    }

    @Test func subRowsSecondRowOnOverlap() {
        let rows = SubtitleTimeline.subRows([cue(0, 3), cue(1, 4)])
        #expect(rows.count == 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SubtitleTimelineTests`
Expected: FAIL — `SubtitleTimeline` not found.

- [ ] **Step 3: Write the cue math**

Create `Sources/CaptureStudio/Studio/SubtitleTimeline.swift`:

```swift
import Foundation

/// Pure cue math for the subtitle track: which cues are visible at a time, lane
/// sub-row packing, and clamping/dropping cues against the clip duration. No
/// AVFoundation, no UI — all unit-tested. Cues are read-only (SRT-driven), so
/// unlike `TextTimeline` there are no move/add/remove operations.
enum SubtitleTimeline {
    /// Every cue live at `t`. Span is half-open `[begin, end)`.
    static func active(at t: Double, cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.filter { $0.begin <= t && t < $0.end }
    }

    /// Drop cues that start at or after `duration`; clamp each remaining end to
    /// `duration`. Preserves order.
    static func clamped(_ cues: [SubtitleCue], duration: Double) -> [SubtitleCue] {
        cues.compactMap { cue in
            guard cue.begin < duration else { return nil }
            var c = cue
            c.end = min(cue.end, duration)
            return c
        }
    }

    /// Greedy interval packing for the lane: cues sorted by `begin`, each placed
    /// in the first sub-row whose last cue ends at or before this cue's begin.
    /// Display-only.
    static func subRows(_ cues: [SubtitleCue]) -> [[SubtitleCue]] {
        let sorted = cues.sorted { $0.begin < $1.begin }
        var rows: [[SubtitleCue]] = []
        for cue in sorted {
            if let i = rows.firstIndex(where: { ($0.last?.end ?? -.infinity) <= cue.begin }) {
                rows[i].append(cue)
            } else {
                rows.append([cue])
            }
        }
        return rows
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SubtitleTimelineTests`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/SubtitleTimeline.swift Tests/CaptureStudioTests/SubtitleTimelineTests.swift
git commit -m "feat: add SubtitleTimeline cue math (active/clamped/subRows)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: Bundle `.srt` file IO

**Files:**
- Modify: `Sources/CaptureStudio/ProjectBundle/ProjectBundle.swift` (add methods to the `struct ProjectBundle`, after `deleteBackgroundImages`, line ~86)
- Test: `Tests/CaptureStudioTests/ProjectBundleTests.swift`

**Interfaces:**
- Produces on `ProjectBundle`: `func subtitleFileURL(_ name: String) -> URL`, `@discardableResult func writeSubtitleFile(from source: URL) throws -> String` (returns `"subtitles.srt"`), `func deleteSubtitleFile()`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CaptureStudioTests/ProjectBundleTests.swift` (inside the existing suite):

```swift
    @Test func writeAndDeleteSubtitleFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("input.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nHi".write(to: src, atomically: true, encoding: .utf8)

        let name = try bundle.writeSubtitleFile(from: src)
        #expect(name == "subtitles.srt")
        let dest = bundle.subtitleFileURL(name)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try String(contentsOf: dest, encoding: .utf8).contains("Hi"))

        bundle.deleteSubtitleFile()
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func writeSubtitleFileReplacesPrevious() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundle = try ProjectBundle.createNew(in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src1 = dir.appendingPathComponent("a.srt")
        try "first".write(to: src1, atomically: true, encoding: .utf8)
        _ = try bundle.writeSubtitleFile(from: src1)

        let src2 = dir.appendingPathComponent("b.srt")
        try "second".write(to: src2, atomically: true, encoding: .utf8)
        let name = try bundle.writeSubtitleFile(from: src2)
        #expect(try String(contentsOf: bundle.subtitleFileURL(name), encoding: .utf8) == "second")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectBundleTests`
Expected: FAIL — `writeSubtitleFile` / `subtitleFileURL` / `deleteSubtitleFile` not found.

- [ ] **Step 3: Add the bundle methods**

In `Sources/CaptureStudio/ProjectBundle/ProjectBundle.swift`, after `deleteBackgroundImages()` (line ~86, before the final closing brace of `struct ProjectBundle`), add:

```swift
    // MARK: - Subtitles (.srt)

    /// URL of the imported subtitle file inside the bundle (so it travels with
    /// the project). `name` is the file name stored in `EditState.subtitles`.
    func subtitleFileURL(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Copy an imported `.srt` into the bundle as `subtitles.srt`, replacing any
    /// previous one. Returns the file name to persist in `EditState`.
    @discardableResult
    func writeSubtitleFile(from source: URL) throws -> String {
        let name = "subtitles.srt"
        let dest = url.appendingPathComponent(name)
        deleteSubtitleFile()
        try FileManager.default.copyItem(at: source, to: dest)
        return name
    }

    /// Remove the imported subtitle file, if any.
    func deleteSubtitleFile() {
        try? FileManager.default.removeItem(at: url.appendingPathComponent("subtitles.srt"))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectBundleTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/ProjectBundle/ProjectBundle.swift Tests/CaptureStudioTests/ProjectBundleTests.swift
git commit -m "feat: add bundle .srt file read/write/delete

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Compositor subtitle rendering

**Files:**
- Modify: `Sources/CaptureStudio/Studio/CameraCompositor.swift` (add `SubtitleTimelineSpec` near `TextTimelineSpec` line ~77; add `CompositorLayout.subtitles` near line ~55; add render loop in `startRequest` before the text loop, line ~295)

**Interfaces:**
- Consumes: `SubtitleStyle`/`SubtitleCue` (Task 1), `SubtitleTimeline.active` (Task 3), existing `textImage(_:canvas:)`.
- Produces: `struct SubtitleTimelineSpec { var style: SubtitleStyle; var cues: [SubtitleCue] }`; `CompositorLayout.subtitles: SubtitleTimelineSpec?`.

- [ ] **Step 1: Add the spec type**

In `CameraCompositor.swift`, after `struct TextTimelineSpec { var blocks: [TextBlock] }` (ends ~line 77), add:

```swift

/// The subtitle cues + shared style for a composition. Cues are read-only; the
/// compositor renders all cues active at the frame time, beneath the text blocks
/// (so manual annotations sit on top).
struct SubtitleTimelineSpec {
    var style: SubtitleStyle
    var cues: [SubtitleCue]
}
```

- [ ] **Step 2: Add the layout field**

In `struct CompositorLayout`, immediately after the `suppressedTextBlockID` property (line ~55), add:

```swift
    /// Subtitle cues (rendered below text blocks). nil / empty = none.
    var subtitles: SubtitleTimelineSpec?
```

- [ ] **Step 3: Add the render loop**

In `startRequest`, immediately **before** the `if let spec = layout.textTimeline {` block (line ~295), add:

```swift
            // Subtitles sit above cursor/camera but below manual text blocks.
            if let sub = layout.subtitles {
                for cue in SubtitleTimeline.active(at: now, cues: sub.cues) {
                    let block = sub.style.asTextBlock(id: cue.id, begin: cue.begin,
                                                      end: cue.end, text: cue.text)
                    if let img = textImage(block, canvas: layout.canvas) {
                        output = img.composited(over: output)
                    }
                }
            }
```

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/CameraCompositor.swift
git commit -m "feat: composite subtitle cues beneath text blocks

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: StudioModel — state, persistence, compositor plumbing

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (published state ~line 52; `needsCompositor` ~line 247; `load()` ~line 334; `saveEdit()` ~line 1508; `buildCompositorComposition` ~line 1365)

**Interfaces:**
- Consumes: `SubtitleTrack` (Task 1), `SubtitleTimeline.clamped` (Task 3), `SubtitleTimelineSpec` (Task 5).
- Produces on `StudioModel`: `@Published private(set) var subtitles: SubtitleTrack?`, `@Published private(set) var subtitleState: SubtitleState`, `@Published var subtitleSelected: Bool`, `@Published private(set) var draggingSubtitle: Bool`, `enum SubtitleState { case idle, applying, removing }`, `var showsSubtitleTimeline: Bool`. (Import/remove/style/selection come in Tasks 7–8.)

- [ ] **Step 1: Add published state**

In `StudioModel.swift`, after the `draggingTextBlockID` / `defaultTextWidth` block (line ~58–60, right after `static let defaultTextWidth = 3.0`), add:

```swift
    /// Subtitle states for the loader gate while importing/removing.
    enum SubtitleState: Equatable { case idle, applying, removing }
    /// Imported subtitle track (nil = none, lane hidden). Cues are read-only;
    /// `style` is the one shared, user-configured look applied to every cue.
    /// Persisted to edit.json; the `.srt` file lives in the bundle.
    @Published private(set) var subtitles: SubtitleTrack?
    /// Loader gate: import/remove run off the main actor so the UI never blocks.
    @Published private(set) var subtitleState: SubtitleState = .idle
    /// The subtitle track is selected for configuration (mutually exclusive with
    /// camera-block and text-block selection).
    @Published var subtitleSelected = false
    /// Set while dragging the subtitle position box on the canvas, so the
    /// compositor suppresses the baked subtitles and the smooth overlay drives
    /// motion. Cleared on drop.
    @Published private(set) var draggingSubtitle = false
```

- [ ] **Step 2: Add the lane-visibility helper**

After `var selectedTextBlock: TextBlock? { ... }` (ends ~line 94), add:

```swift
    /// The subtitle lane shows only when a track with at least one cue exists.
    var showsSubtitleTimeline: Bool {
        guard let s = subtitles else { return false }
        return !s.cues.isEmpty
    }
```

- [ ] **Step 3: Extend `needsCompositor`**

In `var needsCompositor: Bool` (line ~247), add the subtitle clause. Change:

```swift
            || !textBlocks.isEmpty
```

to:

```swift
            || !textBlocks.isEmpty
            || showsSubtitleTimeline
```

- [ ] **Step 4: Load subtitles in `load()`**

In `load()`, immediately after `textBlocks = edit.textBlocks` (line ~334), add:

```swift
            // Clamp cues to the actual clip; a track whose cues all fall past the
            // end loads as no subtitles (the .srt file is left in the bundle).
            if let track = edit.subtitles {
                let cues = SubtitleTimeline.clamped(track.cues, duration: duration)
                subtitles = cues.isEmpty ? nil
                    : SubtitleTrack(srtFilename: track.srtFilename,
                                    style: track.style, cues: cues)
            }
```

- [ ] **Step 5: Persist subtitles in `saveEdit()`**

In `saveEdit()`, change the `EditState(...)` final argument from:

```swift
            textBlocks: textBlocks
        )
```

to:

```swift
            textBlocks: textBlocks,
            subtitles: subtitles
        )
```

- [ ] **Step 6: Plumb subtitles into the compositor**

In `buildCompositorComposition`, immediately after the `if !textBlocks.isEmpty { ... }` block (ends ~line 1365), add:

```swift
        // Subtitle cues (rendered below text blocks). Suppressed entirely while
        // the canvas position box is being dragged — the smooth overlay drives
        // motion, the cue re-bakes at the dropped position.
        if let track = subtitles, !track.cues.isEmpty, !draggingSubtitle {
            layout.subtitles = SubtitleTimelineSpec(style: track.style, cues: track.cues)
        }
```

- [ ] **Step 7: Verify it builds**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 8: Run the full suite (no regressions)**

Run: `swift test`
Expected: PASS — all tests (109 + the new ones) green.

- [ ] **Step 9: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift
git commit -m "feat: persist + composite subtitles in StudioModel

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: StudioModel — import & remove with loader

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (add a `MARK: - Subtitles` section after the text z-order/style methods, ~line 923)

**Interfaces:**
- Consumes: `SubtitleParser.parse` (Task 2), `SubtitleTimeline.clamped` (Task 3), bundle IO (Task 4), `refreshPlayerItemForCanvasChange`, `applyVideoComposition`, `saveEdit` (existing).
- Produces on `StudioModel`: `func importSubtitles(from url: URL)`, `func removeSubtitles()`.

- [ ] **Step 1: Add import / remove methods**

In `StudioModel.swift`, after `func setTextShadow(...)` (line ~923) and before `func selectBlock(...)` (line ~927), add:

```swift
    // MARK: - Subtitles

    /// Import an `.srt`: copy it into the bundle, parse + clamp its cues, and
    /// show the subtitle lane. Runs off the main actor with a loader. Replacing
    /// an existing track preserves the current style. No-op while already busy.
    func importSubtitles(from url: URL) {
        guard subtitleState == .idle else { return }
        subtitleState = .applying
        let bundle = self.bundle
        let duration = self.duration
        let existingStyle = subtitles?.style
        Task {
            let track: SubtitleTrack? = await Task.detached {
                guard let name = try? bundle.writeSubtitleFile(from: url) else { return nil }
                let fileURL = bundle.subtitleFileURL(name)
                let raw = (try? String(contentsOf: fileURL, encoding: .utf8))
                    ?? (try? String(contentsOf: fileURL)) ?? ""
                let cues = SubtitleTimeline.clamped(SubtitleParser.parse(raw), duration: duration)
                guard !cues.isEmpty else { return nil }
                return SubtitleTrack(srtFilename: name,
                                     style: existingStyle ?? SubtitleStyle(), cues: cues)
            }.value

            guard let track else {
                bundle.deleteSubtitleFile()
                subtitleState = .idle
                Log.studio.error("subtitle import failed or produced no cues")
                return
            }
            subtitles = track
            subtitleSelected = true
            selectedTextBlockID = nil
            selectedBlockID = nil
            editingTextBlockID = nil
            refreshPlayerItemForCanvasChange()
            applyVideoComposition()
            saveEdit()
            subtitleState = .idle
        }
    }

    /// Remove the subtitle track + its `.srt` and hide the lane. Loader-gated.
    func removeSubtitles() {
        guard subtitleState == .idle, subtitles != nil else { return }
        subtitleState = .removing
        let bundle = self.bundle
        Task {
            await Task.detached { bundle.deleteSubtitleFile() }.value
            subtitles = nil
            subtitleSelected = false
            draggingSubtitle = false
            refreshPlayerItemForCanvasChange()
            applyVideoComposition()
            saveEdit()
            subtitleState = .idle
        }
    }
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: Build complete, no errors. (If the compiler flags `bundle` as non-Sendable in the detached task, it is an internal struct of `Sendable` members and is implicitly Sendable — no annotation needed. Confirm the build is clean.)

- [ ] **Step 3: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift
git commit -m "feat: import/remove subtitles with loader gate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 8: StudioModel — style setters, selection, position drag

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioModel.swift` (extend the `MARK: - Subtitles` section from Task 7; touch `selectTextBlock` ~line 705, `selectBlock` ~line 929, `deselectAll` ~line 828)

**Interfaces:**
- Produces on `StudioModel`: `func selectSubtitles(_ on: Bool)`, `func commitSubtitleEdit()`, the `setSubtitle*` setters (`FontName/FontSize/Weight/ColorHex/Alignment/BoxEnabled/BoxHex/BoxOpacity/StrokeWidth/StrokeHex/Shadow`), `func beginDraggingSubtitle()`, `func dragSubtitlePosition(x:y:)`, `func endDraggingSubtitle()`.

- [ ] **Step 1: Add selection, style setters, and drag**

In `StudioModel.swift`, at the end of the `MARK: - Subtitles` section (after `removeSubtitles()` from Task 7), add:

```swift
    /// Select the subtitle track for configuration (clears camera/text
    /// selection); pass false to deselect.
    func selectSubtitles(_ on: Bool) {
        subtitleSelected = on
        if on {
            selectedTextBlockID = nil
            selectedBlockID = nil
            editingTextBlockID = nil
        }
    }

    func commitSubtitleEdit() { saveEdit() }

    /// Mutate the shared subtitle style live (applies to every cue). Discrete
    /// edits commit immediately; slider drags pass `commit: false` and persist on
    /// end via `commitSubtitleEdit`.
    private func updateSubtitleStyle(commit: Bool, _ mutate: (inout SubtitleStyle) -> Void) {
        guard subtitles != nil else { return }
        mutate(&subtitles!.style)
        applyVideoComposition()
        if commit { saveEdit() }
    }

    func setSubtitleFontName(_ name: String) { updateSubtitleStyle(commit: true) { $0.fontName = name } }
    func setSubtitleFontSize(_ v: Double) { updateSubtitleStyle(commit: false) { $0.fontSize = min(max(0.01, v), 0.5) } }
    func setSubtitleWeight(_ w: TextWeight) { updateSubtitleStyle(commit: true) { $0.fontWeight = w } }
    func setSubtitleColorHex(_ hex: String) { updateSubtitleStyle(commit: true) { $0.colorHex = hex } }
    func setSubtitleAlignment(_ a: TextAlignmentH) { updateSubtitleStyle(commit: true) { $0.alignment = a } }
    func setSubtitleBoxEnabled(_ on: Bool) { updateSubtitleStyle(commit: true) { $0.boxEnabled = on } }
    func setSubtitleBoxHex(_ hex: String) { updateSubtitleStyle(commit: true) { $0.boxHex = hex } }
    func setSubtitleBoxOpacity(_ v: Double) { updateSubtitleStyle(commit: false) { $0.boxOpacity = min(max(0, v), 1) } }
    func setSubtitleStrokeWidth(_ v: Double) { updateSubtitleStyle(commit: false) { $0.strokeWidth = min(max(0, v), 0.2) } }
    func setSubtitleStrokeHex(_ hex: String) { updateSubtitleStyle(commit: true) { $0.strokeHex = hex } }
    func setSubtitleShadow(_ on: Bool) { updateSubtitleStyle(commit: true) { $0.shadow = on } }

    /// Begin a canvas position drag: select the track and suppress the baked
    /// subtitles (one recomposite) so the smooth overlay drives motion.
    func beginDraggingSubtitle() {
        selectSubtitles(true)
        draggingSubtitle = true
        applyVideoComposition()
    }

    /// Live position update during a drag — moves the shared style (all cues
    /// follow). No recomposite, so it stays smooth.
    func dragSubtitlePosition(x: Double, y: Double) {
        guard subtitles != nil else { return }
        subtitles!.style.centerX = min(max(0, x), 1)
        subtitles!.style.centerY = min(max(0, y), 1)
    }

    /// End the drag: un-suppress, recomposite at the final position, and persist.
    func endDraggingSubtitle() {
        guard draggingSubtitle else { return }
        draggingSubtitle = false
        applyVideoComposition()
        saveEdit()
    }
```

- [ ] **Step 2: Clear subtitle selection when camera/text is selected**

In `selectTextBlock(_:)` (line ~703), change:

```swift
        selectedTextBlockID = id
        if id != nil { selectedBlockID = nil }
```

to:

```swift
        selectedTextBlockID = id
        if id != nil { selectedBlockID = nil; subtitleSelected = false }
```

In `selectBlock(_:)` (line ~927), change:

```swift
        selectedBlockID = id
        if id != nil { selectedTextBlockID = nil }   // camera vs text: one selection at a time
```

to:

```swift
        selectedBlockID = id
        if id != nil { selectedTextBlockID = nil; subtitleSelected = false }   // one selection at a time
```

- [ ] **Step 3: Clear subtitle selection on deselect-all**

In `deselectAll()` (line ~828), change:

```swift
    func deselectAll() {
        deselectText()
        selectedBlockID = nil
    }
```

to:

```swift
    func deselectAll() {
        deselectText()
        selectedBlockID = nil
        if draggingSubtitle { endDraggingSubtitle() }
        subtitleSelected = false
    }
```

- [ ] **Step 4: Verify it builds**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioModel.swift
git commit -m "feat: subtitle style setters, selection, and canvas drag

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 9: Subtitle timeline lane (read-only)

**Files:**
- Create: `Sources/CaptureStudio/Studio/SubtitleTimelineLane.swift`

**Interfaces:**
- Consumes: `StudioModel.subtitles`, `.subtitleSelected`, `.subtitleState`, `.duration`, `.currentTime`, `selectSubtitles`, `seek`; `SubtitleTimeline.subRows` (Task 3); `TextTimeline.firstVisibleTime` (existing); `StudioModel.compositionFrameRate` (existing).
- Produces: `struct SubtitleTimelineLane: View`.

- [ ] **Step 1: Create the lane view**

Create `Sources/CaptureStudio/Studio/SubtitleTimelineLane.swift`:

```swift
import SwiftUI

/// The subtitle track: a read-only strip showing imported `.srt` cues on the
/// shared time axis. Cues can't be retimed or text-edited (the `.srt` is the
/// source of truth) — tapping a cue seeks to it and selects the track for
/// styling. Cues rarely overlap; when they do the lane packs them into sub-rows
/// via `SubtitleTimeline.subRows`. A loader covers the lane while the track is
/// being applied or removed.
struct SubtitleTimelineLane: View {
    @ObservedObject var model: StudioModel

    private let rowHeight: CGFloat = 22
    private let rowSpacing: CGFloat = 3
    private let maxVisibleRows = 3
    private let laneSpace = "subtitleLane"

    private var cues: [SubtitleCue] { model.subtitles?.cues ?? [] }
    private var rows: [[SubtitleCue]] { SubtitleTimeline.subRows(cues) }

    private var contentHeight: CGFloat {
        let n = max(1, rows.count)
        return CGFloat(n) * rowHeight + CGFloat(max(0, n - 1)) * rowSpacing
    }
    private var visibleHeight: CGFloat {
        let n = min(max(1, rows.count), maxVisibleRows)
        return CGFloat(n) * rowHeight + CGFloat(max(0, n - 1)) * rowSpacing
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ScrollView(.vertical, showsIndicators: rows.count > maxVisibleRows) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(height: contentHeight)

                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowCues in
                        ForEach(rowCues) { cue in
                            cueView(cue, width: width)
                                .offset(y: CGFloat(rowIndex) * (rowHeight + rowSpacing))
                        }
                    }

                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: contentHeight)
                        .offset(x: fraction(model.currentTime) * width - 1)
                        .allowsHitTesting(false)
                }
                .frame(height: contentHeight)
                .coordinateSpace(name: laneSpace)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
                        .onChanged { value in
                            model.seek(to: time(atX: value.location.x, width: width))
                        }
                )
                .overlay { if model.subtitleState != .idle { loader } }
            }
            .frame(height: visibleHeight)
        }
        .frame(height: visibleHeight)
    }

    private var loader: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.thinMaterial)
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func cueView(_ cue: SubtitleCue, width: CGFloat) -> some View {
        let x0 = fraction(cue.begin) * width
        let x1 = fraction(cue.end) * width
        let selected = model.subtitleSelected
        let accent = Color.accentColor
        let bodyW = max(2, x1 - x0)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accent.opacity(selected ? 0.45 : 0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(selected ? accent : .clear, lineWidth: 1.5)
                )
                .frame(width: bodyW, height: rowHeight - 2)

            Text(cue.text.isEmpty ? "—" : cue.text)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .frame(width: bodyW, height: rowHeight - 2, alignment: .leading)
                .allowsHitTesting(false)
        }
        .frame(width: bodyW, height: rowHeight, alignment: .leading)
        .offset(x: x0)
        .contentShape(Rectangle())
        .onTapGesture { select(cue) }
    }

    /// Select the track and seek into the cue's span (frame-aligned so it shows
    /// at the seeked frame).
    private func select(_ cue: SubtitleCue) {
        model.selectSubtitles(true)
        let aligned = TextTimeline.firstVisibleTime(begin: cue.begin,
                                                    fps: StudioModel.compositionFrameRate)
        model.seek(to: min(aligned < cue.end ? aligned : cue.begin, model.duration))
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(min(max(0, seconds / model.duration), 1))
    }
    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1)) * model.duration
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: Build complete, no errors. (Not yet mounted — Task 11 wires it in.)

- [ ] **Step 3: Commit**

```bash
git add Sources/CaptureStudio/Studio/SubtitleTimelineLane.swift
git commit -m "feat: read-only subtitle timeline lane

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 10: Subtitle canvas overlay (drag to reposition)

**Files:**
- Create: `Sources/CaptureStudio/Studio/SubtitleCanvasOverlay.swift`

**Interfaces:**
- Consumes: `StudioModel.subtitles`, `.currentTime`, `.renderSize`, `deselectAll`, `beginDraggingSubtitle`, `dragSubtitlePosition`, `endDraggingSubtitle` (Tasks 7–8); `SubtitleStyle.asTextBlock` (Task 1); `TextImageRenderer.size` (existing).
- Produces: `struct SubtitleCanvasOverlay: View`.

- [ ] **Step 1: Create the overlay view**

Create `Sources/CaptureStudio/Studio/SubtitleCanvasOverlay.swift`:

```swift
import SwiftUI

/// On-canvas affordance for the subtitle track: a draggable selection box around
/// the cue active at the playhead. Dragging repositions the *shared* subtitle
/// style, so every cue moves together. The subtitle text itself is burned into
/// preview frames by the compositor; this view only draws the box. Shown while
/// the subtitle track is selected and a cue is on screen.
///
/// A SwiftUI layer ON TOP of the `NSViewRepresentable` player (SwiftUI
/// `VideoPlayer` SIGABRTs on Command-Line-Tools builds), never a player feature.
struct SubtitleCanvasOverlay: View {
    @ObservedObject var model: StudioModel

    @State private var dragStart: CGPoint?
    private let space = "subtitleCanvas"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Tap empty canvas to deselect.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.deselectAll() }

                if let cue = activeCue, let style = model.subtitles?.style,
                   model.renderSize.width > 0 {
                    let block = style.asTextBlock(id: cue.id, begin: cue.begin,
                                                  end: cue.end, text: cue.text)
                    let videoRect = aspectFitRect(model.renderSize, in: geo.size)
                    let viewScale = videoRect.width / model.renderSize.width
                    let cx = videoRect.minX + CGFloat(style.centerX) * model.renderSize.width * viewScale
                    let cy = videoRect.minY + CGFloat(style.centerY) * model.renderSize.height * viewScale
                    let measured = TextImageRenderer.size(block, canvas: model.renderSize)
                    let boxW = max(measured.width * viewScale, 44)
                    let boxH = max(measured.height * viewScale, 26)

                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .contentShape(Rectangle())
                        .frame(width: boxW, height: boxH)
                        .gesture(moveGesture(viewScale: viewScale))
                        .help("Drag to move all subtitles")
                        .position(x: cx, y: cy)
                }
            }
            .coordinateSpace(name: space)
        }
    }

    /// The cue under the playhead (so the box aligns with what's on screen).
    private var activeCue: SubtitleCue? {
        guard let cues = model.subtitles?.cues else { return nil }
        return cues.first { $0.begin <= model.currentTime && model.currentTime < $0.end }
    }

    private func moveGesture(viewScale: CGFloat) -> some Gesture {
        // Measure in the container's fixed space, NOT the box's local space — the
        // box moves during the drag, which would corrupt the translation.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
            .onChanged { value in
                guard model.renderSize.width > 0, let style = model.subtitles?.style else { return }
                if dragStart == nil {
                    dragStart = CGPoint(x: style.centerX, y: style.centerY)
                    model.beginDraggingSubtitle()
                }
                guard let start = dragStart else { return }
                let dx = Double(value.translation.width / viewScale) / model.renderSize.width
                let dy = Double(value.translation.height / viewScale) / model.renderSize.height
                model.dragSubtitlePosition(x: start.x + dx, y: start.y + dy)
            }
            .onEnded { _ in
                dragStart = nil
                model.endDraggingSubtitle()
            }
    }

    private func aspectFitRect(_ content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: Build complete, no errors. (Not yet mounted — Task 11 wires it in.)

- [ ] **Step 3: Commit**

```bash
git add Sources/CaptureStudio/Studio/SubtitleCanvasOverlay.swift
git commit -m "feat: subtitle canvas overlay (drag to reposition all cues)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 11: StudioWindow wiring + end-to-end manual verification

**Files:**
- Modify: `Sources/CaptureStudio/Studio/StudioWindow.swift` (state ~line 9; canvas ZStack ~line 72; lane row ~line 127; row-2 tool groups ~line 152; add `subtitleControls`, `pickSubtitleFile`, `subtitleStylePopover`, `styleSliderSubtitle` near the text controls/popover, lines ~375 / ~669)

**Interfaces:**
- Consumes: everything from Tasks 6–10 (`subtitles`, `subtitleSelected`, `subtitleState`, `showsSubtitleTimeline`, `importSubtitles`, `removeSubtitles`, `selectSubtitles`, the `setSubtitle*` setters, `commitSubtitleEdit`); existing `Self.fontFamilies`, `textColorRow`. `SubtitleTimelineLane` (Task 9), `SubtitleCanvasOverlay` (Task 10).

- [ ] **Step 1: Add popover state**

In `StudioView` (StudioWindow.swift), after `@State private var showTextStyle = false` (line ~9), add:

```swift
    @State private var showSubtitleStyle = false
```

- [ ] **Step 2: Mount the canvas overlay**

In `canvas(player:)`, after the text overlay block (line ~70–72):

```swift
                    if model.selectedTextBlock != nil {
                        TextCanvasOverlay(model: model)
                    }
```

add:

```swift
                    if model.subtitleSelected {
                        SubtitleCanvasOverlay(model: model)
                    }
```

- [ ] **Step 3: Mount the lane**

In `controlBar`, after the text-lane block (ends ~line 127, the `.popover{...}` on the `TextTimelineLane` row), add:

```swift
            if model.showsSubtitleTimeline {
                laneRow("captions.bubble") { SubtitleTimelineLane(model: model) }
            }
```

- [ ] **Step 4: Add the tool group**

In `controlBar`'s row-2 `FlowLayout`, after `toolGroup { textControls }` (line ~151), add:

```swift
                toolGroup { subtitleControls }
```

- [ ] **Step 5: Add `subtitleControls` + picker**

After the `textControls` computed property (ends ~line 375), add:

```swift
    @ViewBuilder private var subtitleControls: some View {
        if model.subtitles == nil {
            Button { pickSubtitleFile() } label: {
                Image(systemName: "captions.bubble")
            }
            .disabled(model.subtitleState != .idle)
            .help("Import subtitles from an .srt file")
        } else {
            Button {
                model.selectSubtitles(true)
                showSubtitleStyle.toggle()
            } label: {
                Image(systemName: "captions.bubble.fill")
            }
            .disabled(model.subtitleState != .idle)
            .help("Subtitle style & position")
            .popover(isPresented: $showSubtitleStyle, arrowEdge: .bottom) {
                subtitleStylePopover
            }

            Button(role: .destructive) { model.removeSubtitles() } label: {
                Image(systemName: "trash")
            }
            .disabled(model.subtitleState != .idle)
            .help("Remove subtitles")
        }
        if model.subtitleState != .idle {
            ProgressView().controlSize(.small)
        }
    }

    /// Pick a `.srt` file and apply it as the subtitle track.
    private func pickSubtitleFile() {
        let panel = NSOpenPanel()
        if let srt = UTType(filenameExtension: "srt") {
            panel.allowedContentTypes = [srt, .text]
        } else {
            panel.allowedContentTypes = [.text]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.importSubtitles(from: url)
        }
    }
```

- [ ] **Step 6: Add the style popover**

After the `textStylePopover` property and its `styleSliderText` helper (ends ~line 679), add:

```swift
    // MARK: - Subtitle style (one shared config applied to every cue)

    @ViewBuilder
    private var subtitleStylePopover: some View {
        let style = model.subtitles?.style
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Applies to all subtitles").font(.caption).foregroundStyle(.secondary)

                Divider()

                Picker("Font", selection: Binding(
                    get: { style?.fontName ?? "Helvetica" },
                    set: { model.setSubtitleFontName($0) }
                )) {
                    ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()

                Picker("Weight", selection: Binding(
                    get: { style?.fontWeight ?? .semibold },
                    set: { model.setSubtitleWeight($0) }
                )) {
                    ForEach(TextWeight.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                Picker("Align", selection: Binding(
                    get: { style?.alignment ?? .center },
                    set: { model.setSubtitleAlignment($0) }
                )) {
                    Image(systemName: "text.alignleft").tag(TextAlignmentH.leading)
                    Image(systemName: "text.aligncenter").tag(TextAlignmentH.center)
                    Image(systemName: "text.alignright").tag(TextAlignmentH.trailing)
                }
                .pickerStyle(.segmented).labelsHidden()

                styleSliderSubtitle("Size", value: Binding(
                    get: { style?.fontSize ?? 0.05 },
                    set: { model.setSubtitleFontSize($0) }
                ), range: 0.02...0.2)

                textColorRow("Color", hex: style?.colorHex ?? "#FFFFFF") {
                    model.setSubtitleColorHex($0)
                }

                Toggle("Background box", isOn: Binding(
                    get: { style?.boxEnabled ?? false },
                    set: { model.setSubtitleBoxEnabled($0) }
                ))
                if style?.boxEnabled == true {
                    textColorRow("Box color", hex: style?.boxHex ?? "#000000") {
                        model.setSubtitleBoxHex($0)
                    }
                    styleSliderSubtitle("Box opacity", value: Binding(
                        get: { style?.boxOpacity ?? 0.5 },
                        set: { model.setSubtitleBoxOpacity($0) }
                    ), range: 0...1)
                }

                styleSliderSubtitle("Outline", value: Binding(
                    get: { style?.strokeWidth ?? 0 },
                    set: { model.setSubtitleStrokeWidth($0) }
                ), range: 0...0.2)
                if (style?.strokeWidth ?? 0) > 0 {
                    textColorRow("Outline color", hex: style?.strokeHex ?? "#000000") {
                        model.setSubtitleStrokeHex($0)
                    }
                }

                Toggle("Shadow", isOn: Binding(
                    get: { style?.shadow ?? true },
                    set: { model.setSubtitleShadow($0) }
                ))

                Divider()

                Text("Scrub to a subtitle, then drag it on the canvas to reposition.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .frame(width: 280)
        .frame(maxHeight: 420)
    }

    private func styleSliderSubtitle(_ title: String, value: Binding<Double>,
                                     range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range) { editing in
                if !editing { model.commitSubtitleEdit() }
            }
        }
    }
```

- [ ] **Step 7: Verify it builds and tests pass**

Run: `swift build && swift test`
Expected: Build complete; all tests green.

- [ ] **Step 8: Build the app bundle**

Run: `scripts/build-app.sh debug`
Expected: `dist/CaptureStudio.app` packaged, no errors.

- [ ] **Step 9: Create a sample `.srt` for manual testing**

Run:

```bash
cat > /tmp/sample.srt <<'EOF'
1
00:00:00,500 --> 00:00:02,000
First subtitle line

2
00:00:02,500 --> 00:00:04,000
Second line, a bit longer

3
00:00:04,500 --> 00:00:06,000
Third and final line
EOF
```

- [ ] **Step 10: Manual end-to-end verification**

Run: `pkill -x CaptureStudio; open dist/CaptureStudio.app`

Then, with a recording open in Studio, confirm each:
1. The subtitle tool group shows a `captions.bubble` import button.
2. Import `/tmp/sample.srt` → a loader flashes, then the subtitle lane appears with three cues, and the import button becomes the filled icon + a trash button.
3. Scrub the playhead into a cue's span → the styled subtitle renders on the canvas (bottom-center by default).
4. Open the style popover → change size/color/box/outline/shadow → all cues update live; close → reopen the project later and the style persists.
5. Click a cue in the lane → the track selects; drag the on-canvas box → all cues move together; release → position persists.
6. Press play → subtitles appear/disappear at the right times; manual text blocks (if any) draw on top of subtitles.
7. Click the trash button → a loader flashes, the lane disappears, the canvas subtitle clears.
8. Re-import, then Export → open the exported file and confirm subtitles are burned in at the configured style/position.

If any check fails, fix inline and re-run from Step 7.

- [ ] **Step 11: Commit**

```bash
git add Sources/CaptureStudio/Studio/StudioWindow.swift
git commit -m "feat: wire subtitle import, lane, style popover, and canvas overlay into Studio

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-06-23-srt-subtitles-design.md`):
- §1 Data model → Task 1. ✓
- §2 SRT parser → Task 2. ✓
- §3 Import/remove + loader → Tasks 4 (bundle IO), 7 (import/remove + `subtitleState`). ✓
- §4 Compositor integration → Task 5; spec plumbing Task 6. ✓
- §5 Read-only lane → Task 9; mounted Task 11. ✓
- §6 Config inspector + canvas interaction → Tasks 8 (setters/selection/drag), 10 (overlay), 11 (popover). ✓
- §7 Edge cases: single track + style preserved on re-import → Task 7 (`existingStyle`); malformed/empty → Tasks 2 + 7; cues beyond duration → Task 3 `clamped`, applied in Tasks 6 (load) + 7 (import); z-order below text → Task 5 (loop before text loop); export burn-in → free via shared composition, verified Task 11 Step 10.8. ✓
- §8 Testing → Tasks 1–4 carry the pure-helper tests. ✓
- `active cue` math (`SubtitleTimeline.active`) → Task 3, used in Task 5. ✓

**Type consistency:** `SubtitleStyle.asTextBlock(id:begin:end:text:)` defined in Task 1, called identically in Tasks 5 and 10. `SubtitleTimelineSpec { style, cues }` defined Task 5, built in Task 6. `SubtitleState` / `subtitleState` / `subtitleSelected` / `draggingSubtitle` / `showsSubtitleTimeline` declared Task 6, used in Tasks 7–11. `setSubtitle*` names match between Task 8 (definitions) and Task 11 (call sites). Bundle `writeSubtitleFile`/`subtitleFileURL`/`deleteSubtitleFile` defined Task 4, used Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; every run step shows the command + expected result. ✓
