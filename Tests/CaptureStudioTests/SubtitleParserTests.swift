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
