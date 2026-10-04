import FFmpegKit
import Foundation
import Libavcodec
import Libavutil
import Libswresample
import PlayerCore

extension CodecParameters {
    convenience init(context: UnsafeMutablePointer<AVCodecContext>, timeBase: AVRational) throws {
        guard let temp = avcodec_parameters_alloc() else { throw EngineAError("avcodec_parameters_alloc failed") }
        var t: UnsafeMutablePointer<AVCodecParameters>? = temp
        defer { avcodec_parameters_free(&t) }
        try FFmpegError.check(avcodec_parameters_from_context(temp, context), "avcodec_parameters_from_context")
        try self.init(copying: temp, timeBase: timeBase)
    }
}

/// Decodes DTS / TrueHD / other audio and re-encodes it as ALAC, FLAC or AAC.
///
/// Output frames sit on a fixed grid of `frameSize` samples counted from the session origin, so a
/// segment produced after a seek has the same frame boundaries as one produced in order.
/// Output packet timestamps are in samples (time base 1/sampleRate), relative to the origin.
final class AudioTranscoder {
    let target: AudioTranscodeTarget
    let inputTimeBase: AVRational
    let originTimestamp: Int64
    let sampleRate: Int32
    private(set) var frameSize = 4096
    private(set) var encoderParameters: CodecParameters!
    var outputTimeBase: AVRational { AVRational(num: 1, den: sampleRate) }

    private let source: CodecParameters
    private var decoder: UnsafeMutablePointer<AVCodecContext>?
    private var encoder: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var fifo: OpaquePointer?
    private var fifoStartSample: Int64 = 0
    private var aligned = false
    private var pendingDrop = 0

    init(source: CodecParameters, target: AudioTranscodeTarget, originTimestamp: Int64) throws {
        self.source = source
        self.target = target
        self.inputTimeBase = source.timeBase
        self.originTimestamp = originTimestamp
        self.sampleRate = source.pointer.pointee.sample_rate > 0 ? source.pointer.pointee.sample_rate : 48_000
        try openDecoder()
        try openEncoder()
        encoderParameters = try CodecParameters(context: encoder!, timeBase: outputTimeBase)
    }

    deinit {
        avcodec_free_context(&decoder)
        avcodec_free_context(&encoder)
        swr_free(&resampler)
        if let fifo { av_audio_fifo_free(fifo) }
    }

    var codecString: String {
        switch target {
        case .alac: "alac"
        case .flac: "fLaC"
        case .aac51: "mp4a.40.2"
        }
    }

    var outputChannels: Int { Int(encoder?.pointee.ch_layout.nb_channels ?? 0) }

    /// Call after a seek: drops decoder state and re-aligns to the grid.
    func reset() throws {
        if let decoder { avcodec_flush_buffers(decoder) }
        avcodec_free_context(&encoder)
        try openEncoder()
        if let fifo { av_audio_fifo_reset(fifo) }
        aligned = false
        pendingDrop = 0
    }

    func feed(_ input: Packet) throws -> [Packet] {
        guard let decoder, let packet = av_packet_alloc() else { throw EngineAError("Transcoder not ready") }
        var p: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&p) }
        try FFmpegError.check(av_new_packet(packet, Int32(input.data.count)), "av_new_packet")
        input.data.withUnsafeBytes { packet.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: input.data.count) }
        packet.pointee.pts = input.pts
        packet.pointee.dts = input.dts == noPTS ? input.pts : input.dts
        packet.pointee.duration = input.duration

        let sent = avcodec_send_packet(decoder, packet)
        if sent == swift_AVERROR_INVALIDDATA { return [] } // corrupt packet: skip, keep going
        try FFmpegError.check(sent, "avcodec_send_packet")
        try receiveDecodedFrames()
        return try encodeReadyFrames(final: false)
    }

    /// End of stream: encode the partial last frame and drain the encoder.
    func finish() throws -> [Packet] {
        if let decoder {
            avcodec_send_packet(decoder, nil)
            try receiveDecodedFrames()
        }
        return try encodeReadyFrames(final: true)
    }

    // MARK: - Setup

    private func openDecoder() throws {
        guard let codec = avcodec_find_decoder(source.codecID) else { throw EngineAError("No decoder for audio track") }
        decoder = avcodec_alloc_context3(codec)
        guard let decoder else { throw EngineAError("avcodec_alloc_context3 failed") }
        try FFmpegError.check(avcodec_parameters_to_context(decoder, source.pointer), "avcodec_parameters_to_context")
        decoder.pointee.pkt_timebase = source.timeBase
        try FFmpegError.check(avcodec_open2(decoder, codec, nil), "open decoder")
    }

    private var isHighResolution: Bool {
        let id = source.codecID
        return source.pointer.pointee.bits_per_raw_sample > 16 || id == AV_CODEC_ID_TRUEHD || id == AV_CODEC_ID_DTS
    }

    private func openEncoder() throws {
        let name = switch target {
        case .alac: "alac"
        case .flac: "flac"
        case .aac51: "aac"
        }
        guard let codec = avcodec_find_encoder_by_name(name) else { throw EngineAError("Encoder \(name) not in this FFmpeg build") }
        encoder = avcodec_alloc_context3(codec)
        guard let encoder else { throw EngineAError("avcodec_alloc_context3 failed") }

        let sourceChannels = max(1, Int(source.pointer.pointee.ch_layout.nb_channels))
        let wanted = Int32(target == .aac51 ? min(sourceChannels, 6) : min(sourceChannels, 8))
        var chosen = false
        if let layouts = codec.pointee.ch_layouts {
            var i = 0
            while layouts[i].nb_channels != 0 {
                if layouts[i].nb_channels == wanted {
                    av_channel_layout_copy(&encoder.pointee.ch_layout, layouts + i)
                    chosen = true
                    break
                }
                i += 1
            }
        }
        if !chosen { av_channel_layout_default(&encoder.pointee.ch_layout, wanted) }

        let preferred: [AVSampleFormat] = switch target {
        case .alac: isHighResolution ? [AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_S16P] : [AV_SAMPLE_FMT_S16P, AV_SAMPLE_FMT_S32P]
        case .flac: isHighResolution ? [AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S16] : [AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S32]
        case .aac51: [AV_SAMPLE_FMT_FLTP]
        }
        var supported: [AVSampleFormat] = []
        if let formats = codec.pointee.sample_fmts {
            var i = 0
            while formats[i] != AV_SAMPLE_FMT_NONE { supported.append(formats[i]); i += 1 }
        }
        guard let format = preferred.first(where: supported.contains) ?? supported.first else {
            throw EngineAError("Encoder \(name) has no usable sample format")
        }
        encoder.pointee.sample_fmt = format
        encoder.pointee.sample_rate = sampleRate
        encoder.pointee.time_base = outputTimeBase
        encoder.pointee.bits_per_raw_sample = isHighResolution && format != AV_SAMPLE_FMT_FLTP ? 24 : 16
        if target == .aac51 { encoder.pointee.bit_rate = Int64(wanted) * 107_000 }
        encoder.pointee.flags |= 1 << 22 // AV_CODEC_FLAG_GLOBAL_HEADER: codec config goes in the init segment
        try FFmpegError.check(avcodec_open2(encoder, codec, nil), "open \(name) encoder")
        frameSize = encoder.pointee.frame_size > 0 ? Int(encoder.pointee.frame_size) : 4096

        if fifo == nil {
            fifo = av_audio_fifo_alloc(format, encoder.pointee.ch_layout.nb_channels, Int32(frameSize * 4))
            guard fifo != nil else { throw EngineAError("av_audio_fifo_alloc failed") }
        }
    }

    // MARK: - Decode, convert, encode

    private func receiveDecodedFrames() throws {
        guard let decoder, let frame = av_frame_alloc() else { return }
        var f: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&f) }
        while true {
            let ret = avcodec_receive_frame(decoder, frame)
            if ret == swift_AVERROR(EAGAIN) || ret == swift_AVERROR_EOF { return }
            try FFmpegError.check(ret, "avcodec_receive_frame")
            try append(frame)
            av_frame_unref(frame)
        }
    }

    private func append(_ frame: UnsafeMutablePointer<AVFrame>) throws {
        guard let encoder, let fifo else { return }
        if resampler == nil {
            try FFmpegError.check(swr_alloc_set_opts2(&resampler, &encoder.pointee.ch_layout, encoder.pointee.sample_fmt, sampleRate,
                                                      &frame.pointee.ch_layout, AVSampleFormat(rawValue: frame.pointee.format),
                                                      frame.pointee.sample_rate, 0, nil), "swr_alloc_set_opts2")
            try FFmpegError.check(swr_init(resampler), "swr_init")
        }

        if !aligned {
            let ts = frame.pointee.best_effort_timestamp != noPTS ? frame.pointee.best_effort_timestamp : frame.pointee.pts
            guard ts != noPTS else { return }
            let position = av_rescale_q(ts - originTimestamp, inputTimeBase, outputTimeBase)
            let size = Int64(frameSize)
            let grid = position >= 0 ? (position + size - 1) / size * size : -((-position) / size * size)
            pendingDrop = Int(grid - position)
            fifoStartSample = grid
            aligned = true
        }

        let capacity = Int32(frame.pointee.nb_samples) + 256
        var output: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
        try FFmpegError.check(av_samples_alloc_array_and_samples(&output, nil, encoder.pointee.ch_layout.nb_channels, capacity,
                                                                  encoder.pointee.sample_fmt, 0), "av_samples_alloc")
        defer {
            if let output { av_freep(output) }
            av_freep(&output)
        }
        let input = UnsafeMutableRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let converted = swr_convert(resampler, output, capacity, input, frame.pointee.nb_samples)
        try FFmpegError.check(converted, "swr_convert")
        guard converted > 0, let output else { return }
        let planes = UnsafeRawPointer(output).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        try FFmpegError.check(av_audio_fifo_write(fifo, planes, converted), "av_audio_fifo_write")
        if pendingDrop > 0 {
            let drop = min(pendingDrop, Int(av_audio_fifo_size(fifo)))
            av_audio_fifo_drain(fifo, Int32(drop))
            pendingDrop -= drop
        }
    }

    private func encodeReadyFrames(final: Bool) throws -> [Packet] {
        guard let encoder, let fifo else { return [] }
        var packets: [Packet] = []
        while av_audio_fifo_size(fifo) >= Int32(frameSize) || (final && av_audio_fifo_size(fifo) > 0) {
            let count = min(Int32(frameSize), av_audio_fifo_size(fifo))
            guard let frame = av_frame_alloc() else { throw EngineAError("av_frame_alloc failed") }
            var f: UnsafeMutablePointer<AVFrame>? = frame
            defer { av_frame_free(&f) }
            frame.pointee.nb_samples = count
            frame.pointee.format = encoder.pointee.sample_fmt.rawValue
            frame.pointee.sample_rate = sampleRate
            av_channel_layout_copy(&frame.pointee.ch_layout, &encoder.pointee.ch_layout)
            try FFmpegError.check(av_frame_get_buffer(frame, 0), "av_frame_get_buffer")
            let planes = UnsafeRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            av_audio_fifo_read(fifo, planes, count)
            frame.pointee.pts = fifoStartSample
            fifoStartSample += Int64(count)
            try FFmpegError.check(avcodec_send_frame(encoder, frame), "avcodec_send_frame")
            packets += try receiveEncodedPackets()
        }
        if final {
            avcodec_send_frame(encoder, nil)
            packets += try receiveEncodedPackets()
        }
        return packets
    }

    private func receiveEncodedPackets() throws -> [Packet] {
        guard let encoder, let packet = av_packet_alloc() else { return [] }
        var p: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&p) }
        var result: [Packet] = []
        while true {
            let ret = avcodec_receive_packet(encoder, packet)
            if ret == swift_AVERROR(EAGAIN) || ret == swift_AVERROR_EOF { break }
            try FFmpegError.check(ret, "avcodec_receive_packet")
            let data = packet.pointee.data.map { Data(bytes: $0, count: Int(packet.pointee.size)) } ?? Data()
            let duration = packet.pointee.duration > 0 ? packet.pointee.duration : Int64(frameSize)
            result.append(Packet(data: data, pts: packet.pointee.pts, dts: packet.pointee.pts, duration: duration,
                                 streamIndex: -1, isKey: true))
            av_packet_unref(packet)
        }
        return result
    }
}
