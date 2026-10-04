import FFmpegKit
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import PlayerCore

/// Builds fMP4 init segments (ftyp + moov) with FFmpeg's mp4 muxer. Fragments are written by
/// FMP4FragmentWriter, so only the header comes from here.
enum InitSegmentBuilder {
    static func mktag(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    /// Video init. Dolby Vision keeps its configuration record (dvcC/dvvC) unless stripped.
    static func video(_ params: CodecParameters, treatment: VideoTreatment) throws -> Data {
        let copy = try params.copy()
        var tag: UInt32 = 0
        switch copy.codecID {
        case AV_CODEC_ID_HEVC:
            switch treatment {
            case .dolbyVision(let profile) where profile == 5: tag = mktag("dvh1")
            case .stripDolbyVision: copy.removeDolbyVision(); tag = mktag("hvc1")
            default: tag = mktag("hvc1")
            }
        case AV_CODEC_ID_H264:
            tag = mktag("avc1")
        default:
            break
        }
        return try build(copy, codecTag: tag, packets: [])
    }

    /// AC3, EAC3 and TrueHD need packets parsed before the muxer can write their sample entry boxes.
    static func needsPackets(_ id: AVCodecID) -> Bool {
        id == AV_CODEC_ID_AC3 || id == AV_CODEC_ID_EAC3 || id == AV_CODEC_ID_TRUEHD
    }

    static func build(_ params: CodecParameters, codecTag: UInt32, packets: [Packet]) throws -> Data {
        var output: UnsafeMutablePointer<AVFormatContext>?
        try FFmpegError.check(avformat_alloc_output_context2(&output, nil, "mp4", nil), "avformat_alloc_output_context2")
        guard let ctx = output else { throw EngineAError("No output context") }
        defer {
            if ctx.pointee.pb != nil {
                var leftover: UnsafeMutablePointer<UInt8>?
                avio_close_dyn_buf(ctx.pointee.pb, &leftover)
                av_free(leftover)
                ctx.pointee.pb = nil
            }
            avformat_free_context(ctx)
        }
        guard let stream = avformat_new_stream(ctx, nil) else { throw EngineAError("avformat_new_stream failed") }
        try FFmpegError.check(avcodec_parameters_copy(stream.pointee.codecpar, params.pointer), "avcodec_parameters_copy")
        stream.pointee.codecpar.pointee.codec_tag = codecTag
        stream.pointee.time_base = params.timeBase
        // dvcC/dvvC are only written at "unofficial" compliance in FFmpeg 6.1.
        ctx.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL

        try FFmpegError.check(avio_open_dyn_buf(&ctx.pointee.pb), "avio_open_dyn_buf")
        let usePackets = needsPackets(params.codecID)
        var options: OpaquePointer?
        av_dict_set(&options, "movflags",
                    usePackets ? "frag_custom+delay_moov+default_base_moof" : "frag_custom+empty_moov+default_base_moof", 0)
        let header = avformat_write_header(ctx, &options)
        av_dict_free(&options)
        try FFmpegError.check(header, "avformat_write_header")

        if usePackets {
            guard !packets.isEmpty else { throw EngineAError("Init segment for this codec needs packets") }
            var lastDTS = Int64.min
            for source in packets.prefix(8) {
                guard let packet = av_packet_alloc() else { throw EngineAError("av_packet_alloc failed") }
                var p: UnsafeMutablePointer<AVPacket>? = packet
                defer { av_packet_free(&p) }
                try FFmpegError.check(av_new_packet(packet, Int32(source.data.count)), "av_new_packet")
                source.data.withUnsafeBytes { packet.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: source.data.count) }
                let ts = max(source.pts == noPTS ? 0 : source.pts, lastDTS + 1, 0)
                lastDTS = ts
                packet.pointee.pts = rescale(ts, from: params.timeBase, to: stream.pointee.time_base)
                packet.pointee.dts = packet.pointee.pts
                packet.pointee.duration = rescale(source.duration, from: params.timeBase, to: stream.pointee.time_base)
                packet.pointee.stream_index = 0
                packet.pointee.flags = AV_PKT_FLAG_KEY
                try FFmpegError.check(av_write_frame(ctx, packet), "av_write_frame")
            }
            try FFmpegError.check(av_write_frame(ctx, nil), "flush fragment")
        }

        var buffer: UnsafeMutablePointer<UInt8>?
        let size = avio_close_dyn_buf(ctx.pointee.pb, &buffer)
        ctx.pointee.pb = nil
        defer { av_free(buffer) }
        guard let buffer, size > 0 else { throw EngineAError("Muxer wrote nothing") }
        return try MP4Box.initSegment(from: Data(bytes: buffer, count: Int(size)))
    }
}
