import FFmpegKit
import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Bridges RemoteByteSource into a custom AVIOContext. FFmpeg calls these on the demux thread.
final class AVIOReader {
    let source: RemoteByteSource
    private(set) var context: UnsafeMutablePointer<AVIOContext>!
    private var position: Int64 = 0

    init(source: RemoteByteSource) throws {
        self.source = source
        let bufferSize: Int32 = 256 * 1024
        guard let buffer = av_malloc(Int(bufferSize)) else { throw EngineAError("av_malloc failed") }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        context = avio_alloc_context(buffer.assumingMemoryBound(to: UInt8.self), bufferSize, 0, opaque, { opaque, buffer, size in
            let reader = Unmanaged<AVIOReader>.fromOpaque(opaque!).takeUnretainedValue()
            return reader.read(buffer, Int(size))
        }, nil, { opaque, offset, whence in
            let reader = Unmanaged<AVIOReader>.fromOpaque(opaque!).takeUnretainedValue()
            return reader.seek(offset, whence)
        })
        guard context != nil else { av_free(buffer); throw EngineAError("avio_alloc_context failed") }
        context.pointee.seekable = AVIO_SEEKABLE_NORMAL
    }

    deinit {
        if context != nil {
            av_freep(&context.pointee.buffer)
            var c: UnsafeMutablePointer<AVIOContext>? = context
            avio_context_free(&c)
        }
    }

    private func read(_ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int) -> Int32 {
        guard let buffer else { return swift_AVERROR(EINVAL) }
        if position >= source.contentLength { return swift_AVERROR_EOF }
        do {
            let n = try source.read(at: position, into: buffer, count: size)
            if n == 0 { return swift_AVERROR_EOF }
            position += Int64(n)
            return Int32(n)
        } catch {
            return swift_AVERROR(EIO)
        }
    }

    private func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        if whence & AVSEEK_SIZE != 0 { return source.contentLength }
        switch whence & ~AVSEEK_FORCE {
        case SEEK_SET: position = offset
        case SEEK_CUR: position += offset
        case SEEK_END: position = source.contentLength + offset
        default: return Int64(swift_AVERROR(EINVAL))
        }
        return position
    }
}

/// One AVFormatContext over a RemoteByteSource. Not thread safe: use from a single serial queue.
final class Demuxer {
    enum Kind { case matroska, mp4, mpegts, other(String) }

    let reader: AVIOReader
    let context: UnsafeMutablePointer<AVFormatContext>
    let kind: Kind
    private(set) var openMillis = 0
    private var headerIndexCount = 0
    private var headerIndexLastSeconds = 0.0
    private var headerDurationSeconds = 0.0

    init(source: RemoteByteSource, probeSize: Int64 = 5_000_000) throws {
        let started = Date()
        reader = try AVIOReader(source: source)
        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocated = ctx else { throw EngineAError("avformat_alloc_context failed") }
        allocated.pointee.pb = reader.context
        allocated.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        allocated.pointee.probesize = probeSize
        allocated.pointee.max_analyze_duration = 5 * Int64(AV_TIME_BASE)
        // avformat_open_input frees the context on failure.
        try FFmpegError.check(avformat_open_input(&ctx, nil, nil, nil), "avformat_open_input")
        guard let opened = ctx else { throw EngineAError("avformat_open_input returned no context") }
        context = opened
        let name = cString(opened.pointee.iformat.pointee.name) ?? ""
        if name.contains("matroska") { kind = .matroska }
        else if name.contains("mp4") || name.contains("mov") { kind = .mp4 }
        else if name == "mpegts" { kind = .mpegts }
        else { kind = .other(name) }

        // Measure the container's own index before find_stream_info, which adds entries for every
        // packet it reads. Matroska may defer Cues until the first seek, so seek to 0 to load them.
        if let video = videoStreamIndex {
            if case .matroska = kind { av_seek_frame(opened, Int32(video), 0, AVSEEK_FLAG_BACKWARD) }
            let st = opened.pointee.streams[video]!
            let count = Int(avformat_index_get_entries_count(st))
            let last = count > 0 ? avformat_index_get_entry(st, Int32(count - 1)).map { seconds($0.pointee.timestamp, st.pointee.time_base) } : nil
            headerIndexCount = count
            headerIndexLastSeconds = last ?? 0
            headerDurationSeconds = opened.pointee.duration > 0 ? Double(opened.pointee.duration) / Double(AV_TIME_BASE) : 0
        }

        let info = avformat_find_stream_info(opened, nil)
        if info < 0 {
            var c: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&c)
            throw FFmpegError(code: info, context: "avformat_find_stream_info")
        }
        openMillis = Int(Date().timeIntervalSince(started) * 1000)
    }

    deinit {
        var c: UnsafeMutablePointer<AVFormatContext>? = context
        avformat_close_input(&c)
    }

    var streamCount: Int { Int(context.pointee.nb_streams) }

    /// True when the container carries a real keyframe index (Matroska Cues, MP4 sample tables), not
    /// just entries FFmpeg added while reading the first packets.
    var hasContainerIndex: Bool {
        switch kind {
        case .mp4:
            return headerIndexCount > 0
        case .matroska:
            // Without Cues, FFmpeg's fallback seek adds a few entries near the start; real Cues span the file.
            guard headerIndexCount >= 2, headerDurationSeconds > 0 else { return false }
            return headerIndexLastSeconds >= headerDurationSeconds * 0.5
        default:
            return false
        }
    }

    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream> {
        context.pointee.streams[index]!
    }

    var videoStreamIndex: Int? {
        (0..<streamCount).first { i in
            let st = stream(i)
            return st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                && st.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0
        }
    }

    func parameters(_ index: Int) throws -> CodecParameters {
        let st = stream(index)
        return try CodecParameters(copying: st.pointee.codecpar, timeBase: st.pointee.time_base)
    }

    /// Keyframe timestamps from the container index (Matroska Cues: pts; MP4 sample tables: dts).
    func keyframeTimestamps(_ index: Int) -> [Int64] {
        let st = stream(index)
        let count = avformat_index_get_entries_count(st)
        var result: [Int64] = []
        result.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let entry = avformat_index_get_entry(st, i) else { continue }
            if entry.pointee.flags & AVINDEX_KEYFRAME != 0 { result.append(entry.pointee.timestamp) }
        }
        return result.sorted()
    }

    func seek(stream index: Int, to timestamp: Int64) throws {
        try FFmpegError.check(av_seek_frame(context, Int32(index), timestamp, AVSEEK_FLAG_BACKWARD), "av_seek_frame")
    }

    func readPacket() throws -> Packet? {
        guard let packet = av_packet_alloc() else { throw EngineAError("av_packet_alloc failed") }
        var p: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&p) }
        let ret = av_read_frame(context, packet)
        if ret == swift_AVERROR_EOF { return nil }
        try FFmpegError.check(ret, "av_read_frame")
        let data = packet.pointee.data.map { Data(bytes: $0, count: Int(packet.pointee.size)) } ?? Data()
        return Packet(data: data, pts: packet.pointee.pts, dts: packet.pointee.dts, duration: packet.pointee.duration,
                      streamIndex: Int(packet.pointee.stream_index), isKey: packet.pointee.flags & AV_PKT_FLAG_KEY != 0)
    }
}
