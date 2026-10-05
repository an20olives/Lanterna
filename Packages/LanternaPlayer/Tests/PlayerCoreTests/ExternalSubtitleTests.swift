import Foundation
import Testing
@testable import PlayerCore

struct ExternalSubtitleTests {
    static let srt = """
    1
    00:00:01,000 --> 00:00:03,500
    <i>Hello</i> there

    2
    00:01:02,250 --> 00:01:04,000
    Second line
    with two rows

    """

    static let vtt = """
    WEBVTT

    NOTE a comment

    00:05.000 --> 00:07.000 align:middle
    Short timestamp

    01:00:00.000 --> 01:00:02.000
    Long timestamp
    """

    @Test func parsesSRT() {
        let cues = SubtitleParser.parse(Self.srt)
        #expect(cues.count == 2)
        #expect(cues[0].start == 1.0 && cues[0].end == 3.5)
        #expect(cues[0].text == "<i>Hello</i> there")
        #expect(cues[1].start == 62.25)
        #expect(cues[1].text == "Second line\nwith two rows")
    }

    @Test func parsesWebVTTWithShortAndLongTimestampsAndSettings() {
        let cues = SubtitleParser.parse(Self.vtt)
        #expect(cues.map(\.start) == [5, 3600])
        #expect(cues[0].text == "Short timestamp")
        #expect(cues[1].end == 3602)
    }

    @Test func toleratesGarbageAndByteOrderMarks() {
        #expect(SubtitleParser.parse("").isEmpty)
        #expect(SubtitleParser.parse("not a subtitle file").isEmpty)
        #expect(SubtitleParser.parse("\u{FEFF}" + Self.srt).count == 2)
    }

    @Test func decodesCommonEncodings() {
        let latin1 = Data("1\n00:00:01,000 --> 00:00:02,000\ncaf\u{E9}\n".utf8.map { $0 }.prefix(0)) + Data([0x31, 0x0A]) + Data("00:00:01,000 --> 00:00:02,000\ncaf".utf8) + Data([0xE9, 0x0A])
        #expect(SubtitleParser.decode(latin1).contains("café"))
        #expect(SubtitleParser.decode(Data("plain".utf8)) == "plain")
    }

    @Test func cuesForASegmentIncludeOverlaps() {
        let sub = ExternalSubtitle(id: "x", language: "eng", label: "English", cues: SubtitleParser.parse(Self.srt), sourceURL: nil)
        #expect(sub.cues(from: 0, to: 6).map(\.start) == [1.0])
        #expect(sub.cues(from: 3, to: 6).map(\.start) == [1.0], "a cue that is still showing belongs to the next segment too")
        #expect(sub.cues(from: 60, to: 66).map(\.start) == [62.25])
        #expect(sub.cues(from: 10, to: 20).isEmpty)
    }

    @Test func delayShiftsCues() {
        let shifted = SubtitleParser.parse(Self.srt).map { $0.shifted(by: 2) }
        #expect(shifted[0].start == 3.0 && shifted[0].end == 5.5)
        #expect(SubtitleParser.parse(Self.srt)[0].shifted(by: -5).start == 0, "never negative")
    }

    @Test func appearanceMapsToTextStyle() {
        var appearance = SubtitleAppearance()
        #expect(appearance.relativeFontSize == 100)
        appearance.sizePercent = 150
        appearance.color = .yellow
        appearance.background = true
        #expect(appearance.relativeFontSize == 150)
        #expect(appearance.foregroundARGB == [1, 1, 0.92, 0.2])
        #expect(appearance.backgroundARGB?.first == 0.6)
        appearance.background = false
        #expect(appearance.backgroundARGB == nil)
    }
}

struct SubtitlePositionTests {
    @Test func defaultKeepsThePlayersOwnPosition() {
        #expect(SubtitleAppearance().linePositionPercent == nil)
    }

    @Test func raisingMovesTheLineUpAndStopsBeforeMidScreen() {
        #expect(SubtitleAppearance(raisePercent: 16).linePositionPercent == 74)
        #expect(SubtitleAppearance(raisePercent: 80).linePositionPercent == 40)
    }
}
