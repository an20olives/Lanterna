import Foundation
import Testing
@testable import PlayerCore

struct WebVTTTests {
    @Test func srtTextKeepsItalicsAndStripsAlignmentTags() {
        #expect(WebVTT.cueText(fromSRT: "{\\an8}<i>Hello</i>\r\nthere") == "<i>Hello</i>\nthere")
    }

    @Test func srtFontTagsAreRemoved() {
        #expect(WebVTT.cueText(fromSRT: "<font color=\"#ffff00\">Yellow</font>") == "Yellow")
    }

    @Test func assPacketTextIsTheNinthField() {
        // FFmpeg matroska ASS packet: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
        let packet = "12,0,Default,,0,0,0,,{\\i1}Hi{\\i0}, you\\Nthere {\\pos(10,10)}friend"
        #expect(WebVTT.cueText(fromASSPacket: packet) == "<i>Hi</i>, you\nthere friend")
    }

    @Test func assDrawingCommandsAreDropped() {
        #expect(WebVTT.cueText(fromASSPacket: "1,0,Sign,,0,0,0,,{\\p1}m 0 0 l 100 0{\\p0}") == nil)
    }

    @Test func cueTextEscapesAmpersandsAndAngleBracketsThatAreNotTags() {
        #expect(WebVTT.cueText(fromSRT: "Tom & Jerry <3") == "Tom &amp; Jerry &lt;3")
    }

    @Test func segmentHasHeaderTimestampMapAndCues() {
        let text = WebVTT.segment(cues: [
            WebVTTCue(start: 61.5, end: 63.25, text: "Line one"),
            WebVTTCue(start: 3601, end: 3602.001, text: "Hour"),
        ])
        #expect(text == """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000

        00:01:01.500 --> 00:01:03.250
        Line one

        01:00:01.000 --> 01:00:02.001
        Hour


        """)
    }

    @Test func emptySegmentIsStillValid() {
        #expect(WebVTT.segment(cues: []) == "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n")
    }
}

struct LocalRouteTests {
    let token = "abc123"

    @Test(arguments: [
        ("/abc123/master.m3u8", LocalRoute.master),
        ("/abc123/v/index.m3u8", .mediaPlaylist(.video)),
        ("/abc123/v/init.mp4", .initSegment(.video)),
        ("/abc123/v/17.m4s", .segment(.video, 17)),
        ("/abc123/a/2/index.m3u8", .mediaPlaylist(.audio(2))),
        ("/abc123/a/2/init.mp4", .initSegment(.audio(2))),
        ("/abc123/a/2/0.m4s", .segment(.audio(2), 0)),
        ("/abc123/s/5/index.m3u8", .subtitlePlaylist(5)),
        ("/abc123/s/5/3.vtt", .subtitleSegment(5, 3)),
    ])
    func parsesRoutes(path: String, expected: LocalRoute) {
        #expect(LocalRoute(path: path, token: token) == expected)
    }

    @Test(arguments: ["/wrong/master.m3u8", "/abc123/", "/abc123/v/x.m4s", "/abc123/a/x/0.m4s",
                      "/abc123/../etc", "/abc123/v/-1.m4s", "/abc123/master.m3u8/extra"])
    func rejectsEverythingElse(path: String) {
        #expect(LocalRoute(path: path, token: token) == nil)
    }

    @Test func ignoresQueryString() {
        #expect(LocalRoute(path: "/abc123/master.m3u8?x=1", token: token) == .master)
    }
}

struct HTTPRequestHeadTests {
    @Test func parsesGetWithHeaders() throws {
        let raw = Data("GET /t/master.m3u8 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n".utf8)
        let head = try #require(HTTPRequestHead.parse(raw))
        #expect(head.method == "GET")
        #expect(head.path == "/t/master.m3u8")
        #expect(head.headers["connection"] == "keep-alive")
        #expect(head.byteCount == raw.count)
    }

    @Test func incompleteHeadReturnsNil() {
        #expect(HTTPRequestHead.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
    }

    @Test func responseHeadIncludesLengthAndType() {
        let head = HTTPResponse(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data("abc".utf8)).serialized()
        let text = String(decoding: head, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 3\r\n"))
        #expect(text.contains("Content-Type: application/vnd.apple.mpegurl\r\n"))
        #expect(text.hasSuffix("\r\n\r\nabc"))
    }

    @Test func partialContentCarriesExtraHeaders() {
        let response = HTTPResponse(status: 206, contentType: "video/x-matroska", body: Data("ab".utf8),
                                    headers: ["Content-Range": "bytes 10-11/100", "Accept-Ranges": "bytes"])
        let text = String(decoding: response.serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        #expect(text.contains("Content-Range: bytes 10-11/100\r\n"))
        #expect(text.contains("Accept-Ranges: bytes\r\n"))
    }
}

struct StatsTests {
    @Test func medianAndP90UseNearestRank() {
        let values: [Double] = [5, 1, 9, 3, 7, 2, 8, 4, 6, 10]
        #expect(Stats.median(values) == 5.5)
        #expect(Stats.percentile(values, 90) == 9)
    }

    @Test func emptyInputIsNil() {
        #expect(Stats.median([]) == nil)
        #expect(Stats.percentile([], 90) == nil)
    }
}

struct ThumbnailTrackTests {
    func track(count: Int = 25) -> ThumbnailTrack {
        ThumbnailTrack(width: 320, height: 180, columns: 10, rows: 10, thumbnailCount: count, intervalSeconds: 10, bandwidth: 150_000) { _ in Data() }
    }

    @Test func playlistCoversEverySheetAndTheShortLastOne() {
        let text = track(count: 250).playlist()
        #expect(text.contains("#EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=10.000"))
        #expect(text.contains("#EXT-X-IMAGES-ONLY"))
        #expect(text.components(separatedBy: "#EXTINF:1000.000,").count == 3)     // two full sheets of 100 x 10 s
        #expect(text.contains("#EXTINF:500.000,\n2.jpg"))                           // 50 thumbnails left on the last sheet
        #expect(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test func masterLineAndRoutes() {
        #expect(track().masterLine == #"#EXT-X-IMAGE-STREAM-INF:BANDWIDTH=150000,RESOLUTION=320x180,CODECS="jpeg",URI="t/index.m3u8""#)
        #expect(LocalRoute(path: "/tok/t/index.m3u8", token: "tok") == .thumbnailPlaylist)
        #expect(LocalRoute(path: "/tok/t/3.jpg", token: "tok") == .thumbnailSheet(3))
        #expect(LocalRoute(path: "/bad/t/3.jpg", token: "tok") == nil)
        #expect(LocalRoute(path: "/tok/t/x.jpg", token: "tok") == nil)
    }
}
