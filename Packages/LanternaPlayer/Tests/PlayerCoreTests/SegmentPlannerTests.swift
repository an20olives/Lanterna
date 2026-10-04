import Testing
@testable import PlayerCore

struct SegmentPlannerTests {
    @Test func cutsOnFirstKeyframeAtOrAfterTarget() {
        let keyframes: [Double] = [0, 2, 4, 6, 8, 10, 12]
        let plan = SegmentPlanner(targetDuration: 6).plan(keyframes: keyframes, duration: 14)
        #expect(plan.segments.map(\.start) == [0, 6, 12])
        #expect(plan.segments.map(\.end) == [6, 12, 14])
    }

    @Test func irregularGOPsProduceLongerSegmentsAndTargetDurationRoundsUp() {
        let plan = SegmentPlanner(targetDuration: 6).plan(keyframes: [0, 5, 13.5, 20], duration: 26)
        #expect(plan.segments.map(\.start) == [0, 13.5, 20])
        #expect(plan.targetDurationSeconds == 14)
    }

    @Test func tinyTailIsMergedIntoPreviousSegment() {
        let plan = SegmentPlanner(targetDuration: 6).plan(keyframes: [0, 6, 12], duration: 12.4)
        #expect(plan.segments.map(\.start) == [0, 6])
        #expect(plan.segments.last?.end == 12.4)
    }

    @Test func firstSegmentStartsAtFirstKeyframe() {
        let plan = SegmentPlanner(targetDuration: 6).plan(keyframes: [0.042, 6.1, 12.2], duration: 18)
        #expect(plan.segments.first?.start == 0.042)
    }

    @Test func indexesAreSequential() {
        let plan = SegmentPlanner(targetDuration: 6).plan(keyframes: stride(from: 0.0, to: 60, by: 2).map { $0 }, duration: 60)
        #expect(plan.segments.map(\.index) == Array(0..<plan.segments.count))
    }

    @Test func findsSegmentContainingTime() {
        let plan = SegmentPlanner(targetDuration: 6).plan(keyframes: [0, 6, 12], duration: 18)
        #expect(plan.segmentIndex(containing: 0) == 0)
        #expect(plan.segmentIndex(containing: 6) == 1)
        #expect(plan.segmentIndex(containing: 17.9) == 2)
        #expect(plan.segmentIndex(containing: 99) == 2)
    }

    @Test func noKeyframesYieldsEmptyPlan() {
        #expect(SegmentPlanner(targetDuration: 6).plan(keyframes: [], duration: 10).segments.isEmpty)
    }
}

struct PlaylistWriterTests {
    let plan = SegmentPlanner(targetDuration: 6).plan(keyframes: [0, 6, 12], duration: 14.5)

    @Test func mediaPlaylistIsCompleteVOD() {
        let text = PlaylistWriter.mediaPlaylist(plan: plan, initURI: "init.mp4", segmentExtension: "m4s")
        #expect(text == """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.000,
        0.m4s
        #EXTINF:6.000,
        1.m4s
        #EXTINF:2.500,
        2.m4s
        #EXT-X-ENDLIST

        """)
    }

    @Test func subtitlePlaylistHasNoMap() {
        let text = PlaylistWriter.mediaPlaylist(plan: plan, initURI: nil, segmentExtension: "vtt")
        #expect(!text.contains("EXT-X-MAP"))
        #expect(text.contains("0.vtt"))
    }

    @Test func masterPlaylistForDolbyVision81WithAtmosAndSubs() {
        let master = MasterPlaylist(
            video: .init(codecs: "hvc1.2.4.L153.B0", supplementalCodecs: "dvh1.08.06/db1p",
                         width: 3840, height: 2160, frameRate: 23.976, videoRange: .pq,
                         bandwidth: 60_000_000, uri: "v/index.m3u8"),
            audio: [
                .init(id: 1, name: "English Atmos", language: "eng", codecs: "ec-3", channels: "16/JOC",
                      isDefault: true, uri: "a/1/index.m3u8"),
                .init(id: 2, name: "English", language: "eng", codecs: "alac", channels: "6",
                      isDefault: false, uri: "a/2/index.m3u8"),
            ],
            subtitles: [
                .init(id: 3, name: "English", language: "eng", isDefault: false, isForced: false, uri: "s/3/index.m3u8"),
            ])
        let text = PlaylistWriter.masterPlaylist(master)
        #expect(text.contains(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English Atmos",LANGUAGE="eng",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="16/JOC",URI="a/1/index.m3u8""#))
        #expect(text.contains(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="eng",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="6",URI="a/2/index.m3u8""#))
        #expect(text.contains(#"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="eng",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI="s/3/index.m3u8""#))
        #expect(text.contains(#"#EXT-X-STREAM-INF:BANDWIDTH=60000000,CODECS="hvc1.2.4.L153.B0,ec-3,alac",SUPPLEMENTAL-CODECS="dvh1.08.06/db1p",RESOLUTION=3840x2160,FRAME-RATE=23.976,VIDEO-RANGE=PQ,AUDIO="aud",SUBTITLES="subs""#))
        #expect(text.hasSuffix("v/index.m3u8\n"))
    }

    @Test func masterPlaylistWithoutSubtitlesOmitsGroup() {
        let master = MasterPlaylist(
            video: .init(codecs: "avc1.640028", supplementalCodecs: nil, width: 1920, height: 1080,
                         frameRate: 25, videoRange: .sdr, bandwidth: 8_000_000, uri: "v/index.m3u8"),
            audio: [.init(id: 1, name: "Audio", language: nil, codecs: "mp4a.40.2", channels: "2",
                          isDefault: true, uri: "a/1/index.m3u8")],
            subtitles: [])
        let text = PlaylistWriter.masterPlaylist(master)
        #expect(!text.contains("SUBTITLES="))
        #expect(!text.contains("LANGUAGE=\"\""))
    }
}

struct CodecStringTests {
    @Test func hevcMain10FromHvcC() {
        // configurationVersion, profile_space/tier/profile_idc, 4 compat bytes, 6 constraint bytes, level
        let hvcC: [UInt8] = [0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0xB0, 0, 0, 0, 0, 0, 153]
        #expect(CodecString.hevc(hvcC: hvcC, tag: "hvc1") == "hvc1.2.4.L153.B0")
    }

    @Test func hevcMainHighTier() {
        let hvcC: [UInt8] = [0x01, 0x21, 0x60, 0x00, 0x00, 0x00, 0x90, 0, 0, 0, 0, 0, 120]
        #expect(CodecString.hevc(hvcC: hvcC, tag: "hvc1") == "hvc1.1.6.H120.90")
    }

    @Test func avcFromAvcC() {
        #expect(CodecString.avc(avcC: [0x01, 0x64, 0x00, 0x28, 0xFF]) == "avc1.640028")
    }

    @Test func dolbyVisionStrings() {
        #expect(CodecString.dolbyVision(profile: 5, level: 6, tag: "dvh1") == "dvh1.05.06")
        #expect(CodecString.dolbyVisionSupplemental(profile: 8, level: 6, compatibilityID: 1) == "dvh1.08.06/db1p")
        #expect(CodecString.dolbyVisionSupplemental(profile: 8, level: 9, compatibilityID: 4) == "dvh1.08.09/db4h")
        #expect(CodecString.dolbyVisionSupplemental(profile: 8, level: 6, compatibilityID: 2) == nil)
    }

    @Test func truncatedConfigReturnsNil() {
        #expect(CodecString.hevc(hvcC: [0x01, 0x02], tag: "hvc1") == nil)
    }
}
