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
