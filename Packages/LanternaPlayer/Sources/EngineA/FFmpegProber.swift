import FFmpegKit
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import PlayerCore

public struct ProbeResult: Sendable {
    public var probe: StreamProbe
    /// Keyframe times in seconds from the container index, for segment planning.
    public var keyframeTimes: [Double]
}

/// Opens a stream through FFmpeg and describes what it really contains.
public enum FFmpegProber {
    public static func probe(_ source: RemoteByteSource) async throws -> ProbeResult {
        guard source.rangeSupported else {
            // Probing without Range would mean downloading the file. The router sends these to Engine C.
            let probe = StreamProbe(container: .other("unknown"), durationSeconds: nil, seekIndex: .none,
                                    rangeSupported: false, contentLength: source.contentLength, bitRate: nil,
                                    video: nil, audio: [], subtitles: [], chapters: [], probeMillis: 0)
            return ProbeResult(probe: probe, keyframeTimes: [])
        }
        return try await Blocking.run {
            let demuxer = try Demuxer(source: source)
            return describe(demuxer, source: source)
        }
    }

    /// The video stream's codec parameters (tests and init-segment work).
    static func videoParameters(_ source: RemoteByteSource) async throws -> CodecParameters {
        try await Blocking.run {
            let demuxer = try Demuxer(source: source)
            guard let index = demuxer.videoStreamIndex else { throw EngineAError("No video stream") }
            return try demuxer.parameters(index)
        }
    }

    static func describe(_ demuxer: Demuxer, source: RemoteByteSource) -> ProbeResult {
        let ctx = demuxer.context.pointee
        let container: Container
        switch demuxer.kind {
        case .matroska: container = .matroska
        case .mp4: container = .mp4
        case .mpegts: container = .mpegts
        case .other(let name): container = .other(name)
        }

        var video: VideoInfo?
        var keyframeTimes: [Double] = []
        var audio: [AudioTrackInfo] = []
        var subtitles: [SubtitleTrackInfo] = []

        for i in 0..<demuxer.streamCount {
            let st = demuxer.stream(i).pointee
            let par = st.codecpar.pointee
            let language = metadataValue(st.metadata, "language").flatMap { $0 == "und" ? nil : $0 }
            let title = metadataValue(st.metadata, "title")
            switch par.codec_type {
            case AVMEDIA_TYPE_VIDEO where video == nil && st.disposition & AV_DISPOSITION_ATTACHED_PIC == 0:
                video = describeVideo(par, stream: st)
                keyframeTimes = demuxer.keyframeTimestamps(i).map { seconds($0, st.time_base) }
            case AVMEDIA_TYPE_AUDIO:
                audio.append(AudioTrackInfo(
                    index: i, codec: audioCodec(par), channels: Int(par.ch_layout.nb_channels),
                    hasAtmos: (par.codec_id == AV_CODEC_ID_EAC3 || par.codec_id == AV_CODEC_ID_TRUEHD) && par.profile == 30,
                    language: language, title: title, isDefault: st.disposition & dispositionDefault != 0,
                    isCommentary: st.disposition & dispositionComment != 0,
                    isAudioDescription: st.disposition & dispositionVisualImpaired != 0))
            case AVMEDIA_TYPE_SUBTITLE:
                subtitles.append(SubtitleTrackInfo(
                    index: i, format: subtitleFormat(par.codec_id), language: language, title: title,
                    isForced: st.disposition & dispositionForced != 0, isDefault: st.disposition & dispositionDefault != 0))
            default:
                break
            }
        }

        var chapters: [Chapter] = []
        for i in 0..<Int(ctx.nb_chapters) {
            guard let chapter = ctx.chapters[i]?.pointee else { continue }
            chapters.append(Chapter(start: seconds(chapter.start, chapter.time_base), end: seconds(chapter.end, chapter.time_base),
                                    title: metadataValue(chapter.metadata, "title")))
        }

        let duration = ctx.duration == noPTS || ctx.duration <= 0 ? nil : Double(ctx.duration) / Double(AV_TIME_BASE)
        let probe = StreamProbe(
            container: container, durationSeconds: duration,
            seekIndex: demuxer.hasContainerIndex && !keyframeTimes.isEmpty ? .keyframeIndex(count: keyframeTimes.count) : .none,
            rangeSupported: source.rangeSupported, contentLength: source.contentLength,
            bitRate: ctx.bit_rate > 0 ? Int(ctx.bit_rate) : nil,
            video: video, audio: audio, subtitles: subtitles, chapters: chapters, probeMillis: demuxer.openMillis)
        return ProbeResult(probe: probe, keyframeTimes: keyframeTimes)
    }

    static func describeVideo(_ par: AVCodecParameters, stream: AVStream) -> VideoInfo {
        let codec: VideoCodec
        switch par.codec_id {
        case AV_CODEC_ID_H264: codec = .h264
        case AV_CODEC_ID_HEVC: codec = .hevc
        case AV_CODEC_ID_AV1: codec = .av1
        case AV_CODEC_ID_VC1, AV_CODEC_ID_WMV3: codec = .vc1
        case AV_CODEC_ID_MPEG2VIDEO: codec = .mpeg2
        case AV_CODEC_ID_VP9: codec = .vp9
        default: codec = .other(cString(avcodec_get_name(par.codec_id)) ?? "unknown")
        }
        let depth = av_pix_fmt_desc_get(AVPixelFormat(rawValue: par.format)).map { Int($0.pointee.comp.0.depth) } ?? 8
        let rate = stream.avg_frame_rate.num > 0 && stream.avg_frame_rate.den > 0 ? stream.avg_frame_rate : stream.r_frame_rate

        var range = DynamicRange.sdr
        withUnsafePointer(to: par) { pointer in
            if let side = av_packet_side_data_get(pointer.pointee.coded_side_data, pointer.pointee.nb_coded_side_data,
                                                  AV_PKT_DATA_DOVI_CONF) {
                let record = side.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
                range = .dolbyVision(DoviConfig(profile: Int(record.dv_profile), level: Int(record.dv_level),
                                                blSignalCompatibilityID: Int(record.dv_bl_signal_compatibility_id),
                                                rpuPresent: record.rpu_present_flag != 0, elPresent: record.el_present_flag != 0))
            } else if par.color_trc == AVCOL_TRC_SMPTE2084 {
                range = .hdr10
            } else if par.color_trc == AVCOL_TRC_ARIB_STD_B67 {
                range = .hlg
            }
        }

        return VideoInfo(codec: codec, profile: cString(avcodec_profile_name(par.codec_id, par.profile)),
                         level: par.level > 0 ? Int(par.level) : nil, bitDepth: depth,
                         width: Int(par.width), height: Int(par.height),
                         frameRate: Rational(Int(rate.num), Int(rate.den)),
                         interlaced: par.field_order != AV_FIELD_PROGRESSIVE && par.field_order != AV_FIELD_UNKNOWN,
                         dynamicRange: range)
    }

    static func audioCodec(_ par: AVCodecParameters) -> AudioCodec {
        switch par.codec_id {
        case AV_CODEC_ID_AAC: return .aac
        case AV_CODEC_ID_AC3: return .ac3
        case AV_CODEC_ID_EAC3: return .eac3
        case AV_CODEC_ID_TRUEHD: return .truehd
        case AV_CODEC_ID_DTS:
            switch par.profile {
            case 60, 61, 62: return .dtsHDMA   // DTS-HD MA, MA + DTS:X, MA + DTS:X IMAX
            case 50: return .dtsHRA
            default: return .dts
            }
        case AV_CODEC_ID_FLAC: return .flac
        case AV_CODEC_ID_OPUS: return .opus
        case AV_CODEC_ID_MP3: return .mp3
        case AV_CODEC_ID_ALAC: return .alac
        default:
            let name = cString(avcodec_get_name(par.codec_id)) ?? "unknown"
            return name.hasPrefix("pcm_") ? .pcm : .other(name)
        }
    }

    static func subtitleFormat(_ id: AVCodecID) -> SubtitleFormat {
        switch id {
        case AV_CODEC_ID_SUBRIP, AV_CODEC_ID_SRT, AV_CODEC_ID_TEXT: return .srt
        case AV_CODEC_ID_ASS: return .ass
        case AV_CODEC_ID_SSA: return .ssa
        case AV_CODEC_ID_WEBVTT: return .webvtt
        case AV_CODEC_ID_MOV_TEXT: return .movText
        case AV_CODEC_ID_HDMV_PGS_SUBTITLE: return .pgs
        case AV_CODEC_ID_DVD_SUBTITLE: return .vobsub
        case AV_CODEC_ID_DVB_SUBTITLE: return .dvb
        default: return .other(cString(avcodec_get_name(id)) ?? "unknown")
        }
    }
}
