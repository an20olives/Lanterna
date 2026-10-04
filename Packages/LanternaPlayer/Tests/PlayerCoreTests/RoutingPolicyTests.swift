import Testing
@testable import PlayerCore

/// Probe fixtures shaped like the P0 corpus in docs/p0-player-spike.md.
enum Fixture {
    static func video(
        _ codec: VideoCodec = .hevc, profile: String? = "Main 10", bitDepth: Int = 10,
        range: DynamicRange = .sdr, interlaced: Bool = false
    ) -> VideoInfo {
        VideoInfo(codec: codec, profile: profile, level: 153, bitDepth: bitDepth,
                  width: 3840, height: 2160, frameRate: Rational(24000, 1001),
                  interlaced: interlaced, dynamicRange: range)
    }

    static func audio(_ codec: AudioCodec, index: Int = 1, channels: Int = 6, atmos: Bool = false,
                      language: String? = "eng", commentary: Bool = false) -> AudioTrackInfo {
        AudioTrackInfo(index: index, codec: codec, channels: channels, hasAtmos: atmos,
                       language: language, title: nil, isDefault: index == 1,
                       isCommentary: commentary, isAudioDescription: false)
    }

    static func sub(_ format: SubtitleFormat, index: Int, language: String = "eng",
                    forced: Bool = false, isDefault: Bool = false) -> SubtitleTrackInfo {
        SubtitleTrackInfo(index: index, format: format, language: language, title: nil,
                          isForced: forced, isDefault: isDefault)
    }

    static func probe(
        container: Container = .matroska, seekIndex: SeekIndex = .keyframeIndex(count: 900),
        rangeSupported: Bool = true, video: VideoInfo? = video(),
        audio: [AudioTrackInfo] = [audio(.eac3)], subtitles: [SubtitleTrackInfo] = []
    ) -> StreamProbe {
        StreamProbe(container: container, durationSeconds: 7200, seekIndex: seekIndex,
                    rangeSupported: rangeSupported, contentLength: 40_000_000_000, bitRate: 45_000_000,
                    video: video, audio: audio, subtitles: subtitles, chapters: [], probeMillis: 800)
    }

    static let context = RoutingContext(
        preferences: PlayerPreferences(audioLanguages: ["eng"], subtitleLanguages: ["eng"],
                                       subtitlesEnabled: false, showForcedSubtitles: true),
        hardware: HardwareCapabilities(av1HardwareDecode: false),
        transcodeTarget: .alac)
}

struct RoutingPolicyTests {
    let policy = DefaultRoutingPolicy()

    @Test func dolbyVisionP81WithTrueHDGoesToRemuxWithTranscode() {
        let probe = Fixture.probe(
            video: Fixture.video(range: .dolbyVision(DoviConfig(profile: 8, level: 6, blSignalCompatibilityID: 1,
                                                                rpuPresent: true, elPresent: false))),
            audio: [Fixture.audio(.truehd, channels: 8, atmos: true)])
        let d = policy.decide(probe, context: Fixture.context)
        #expect(d.engine == .aRemux)
        #expect(d.audioPlan == [AudioPlan(trackIndex: 1, action: .transcode(.alac))])
        #expect(d.reasons.contains(.audioTranscodeTrueHD))
        #expect(d.videoTreatment == .dolbyVision(profile: 8))
    }

    @Test func eac3AtmosIsCopied() {
        let d = policy.decide(Fixture.probe(audio: [Fixture.audio(.eac3, atmos: true)]), context: Fixture.context)
        #expect(d.engine == .aRemux)
        #expect(d.audioPlan == [AudioPlan(trackIndex: 1, action: .copy)])
    }

    @Test func dtsHDIsTranscodedToConfiguredTarget() {
        var ctx = Fixture.context
        ctx.transcodeTarget = .aac51
        let d = policy.decide(Fixture.probe(audio: [Fixture.audio(.dtsHDMA, channels: 8)]), context: ctx)
        #expect(d.audioPlan == [AudioPlan(trackIndex: 1, action: .transcode(.aac51))])
        #expect(d.reasons.contains(.audioTranscodeDTS))
    }

    @Test func mp4WithAppleNativeCodecsPlaysDirect() {
        let probe = Fixture.probe(container: .mp4, video: Fixture.video(.h264, profile: "High", bitDepth: 8),
                                  audio: [Fixture.audio(.aac, channels: 2)])
        #expect(policy.decide(probe, context: Fixture.context).engine == .aDirect)
    }

    @Test func mp4NeedingTranscodeIsRemuxedNotDirect() {
        let probe = Fixture.probe(container: .mp4, video: Fixture.video(.h264, profile: "High", bitDepth: 8),
                                  audio: [Fixture.audio(.dts)])
        #expect(policy.decide(probe, context: Fixture.context).engine == .aRemux)
    }

    @Test func matroskaWithoutCuesGoesToC() {
        let d = policy.decide(Fixture.probe(seekIndex: .none), context: Fixture.context)
        #expect(d.engine == .c)
        #expect(d.reasons == [.noSeekIndex])
    }

    @Test func noRangeSupportGoesToC() {
        let d = policy.decide(Fixture.probe(rangeSupported: false), context: Fixture.context)
        #expect(d.engine == .c)
        #expect(d.reasons.contains(.noRangeSupport))
    }

    @Test func hi10pGoesToC() {
        let d = policy.decide(Fixture.probe(video: Fixture.video(.h264, profile: "High 10", bitDepth: 10)),
                              context: Fixture.context)
        #expect(d.engine == .c)
        #expect(d.reasons.contains(.hi10p))
    }

    @Test func av1GoesToCWithoutHardwareDecode() {
        let d = policy.decide(Fixture.probe(video: Fixture.video(.av1)), context: Fixture.context)
        #expect(d.engine == .c)
        #expect(d.reasons.contains(.av1NoHardwareDecode))
    }

    @Test func av1StaysInAWithHardwareDecode() {
        var ctx = Fixture.context
        ctx.hardware.av1HardwareDecode = true
        #expect(policy.decide(Fixture.probe(video: Fixture.video(.av1)), context: ctx).engine == .aRemux)
    }

    @Test(arguments: [VideoCodec.vc1, .mpeg2, .vp9])
    func legacyOrUnsupportedVideoGoesToC(codec: VideoCodec) {
        #expect(policy.decide(Fixture.probe(video: Fixture.video(codec)), context: Fixture.context).engine == .c)
    }

    @Test func interlacedGoesToC() {
        let d = policy.decide(Fixture.probe(video: Fixture.video(.h264, profile: "High", bitDepth: 8, interlaced: true)),
                              context: Fixture.context)
        #expect(d.engine == .c)
        #expect(d.reasons.contains(.interlaced))
    }

    @Test func pgsAloneInPreferredLanguageWithSubtitlesOnGoesToC() {
        var ctx = Fixture.context
        ctx.preferences.subtitlesEnabled = true
        let probe = Fixture.probe(subtitles: [Fixture.sub(.pgs, index: 2)])
        let d = policy.decide(probe, context: ctx)
        #expect(d.engine == .c)
        #expect(d.reasons.contains(.imageSubtitleRequired))
    }

    @Test func forcedPGSGoesToCEvenWithSubtitlesOff() {
        let probe = Fixture.probe(subtitles: [Fixture.sub(.pgs, index: 2, forced: true)])
        #expect(policy.decide(probe, context: Fixture.context).engine == .c)
    }

    @Test func pgsWithTextAlternativeStaysInAAndIsOfferedForReroute() {
        var ctx = Fixture.context
        ctx.preferences.subtitlesEnabled = true
        let probe = Fixture.probe(subtitles: [Fixture.sub(.pgs, index: 2), Fixture.sub(.srt, index: 3)])
        let d = policy.decide(probe, context: ctx)
        #expect(d.engine == .aRemux)
        #expect(d.webVTTTracks == [3])
        #expect(d.imageSubtitleTracks == [2])
    }

    @Test func assAndSrtBecomeWebVTT() {
        let probe = Fixture.probe(subtitles: [Fixture.sub(.ass, index: 2), Fixture.sub(.srt, index: 3, language: "spa")])
        let d = policy.decide(probe, context: Fixture.context)
        #expect(d.webVTTTracks == [2, 3])
        #expect(d.reasons.contains(.textSubtitlesToWebVTT))
    }

    @Test func dolbyVisionProfile7PlaysAsHDR10() {
        let p7 = DoviConfig(profile: 7, level: 6, blSignalCompatibilityID: 6, rpuPresent: true, elPresent: true)
        let d = policy.decide(Fixture.probe(video: Fixture.video(range: .dolbyVision(p7))), context: Fixture.context)
        #expect(d.engine == .aRemux)
        #expect(d.videoTreatment == .stripDolbyVision)
        #expect(d.reasons.contains(.dvProfile7AsHDR10))
    }

    @Test func dolbyVisionProfile5KeepsDV() {
        let p5 = DoviConfig(profile: 5, level: 6, blSignalCompatibilityID: 0, rpuPresent: true, elPresent: false)
        let d = policy.decide(Fixture.probe(video: Fixture.video(range: .dolbyVision(p5))), context: Fixture.context)
        #expect(d.videoTreatment == .dolbyVision(profile: 5))
    }

    @Test func probeFailureGoesToC() {
        let d = policy.decide(nil, context: Fixture.context)
        #expect(d.engine == .c)
        #expect(d.reasons == [.probeFailed])
    }

    @Test func forcedEngineIsHonoredAndLogged() {
        var ctx = Fixture.context
        ctx.forcedEngine = .c
        let d = policy.decide(Fixture.probe(), context: ctx)
        #expect(d.engine == .c)
        #expect(d.reasons.contains(.forcedByHarness))
    }

    @Test func allAudioUnplayableGoesToC() {
        let d = policy.decide(Fixture.probe(audio: [Fixture.audio(.other("cook"))]), context: Fixture.context)
        #expect(d.engine == .c)
        #expect(d.reasons.contains(.noPlayableAudio))
    }

    @Test func unknownAudioTrackIsDroppedWhenAnotherIsPlayable() {
        let d = policy.decide(Fixture.probe(audio: [Fixture.audio(.eac3), Fixture.audio(.other("cook"), index: 2)]),
                              context: Fixture.context)
        #expect(d.engine == .aRemux)
        #expect(d.audioPlan == [AudioPlan(trackIndex: 1, action: .copy), AudioPlan(trackIndex: 2, action: .drop)])
    }
}
