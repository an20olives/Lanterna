import FFmpegKit
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import PlayerCore

public struct FFmpegError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let context: String

    public var description: String { "\(context): \(Self.message(code)) (\(code))" }

    static func message(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }

    @discardableResult
    static func check(_ code: Int32, _ context: @autoclosure () -> String) throws -> Int32 {
        if code < 0 { throw FFmpegError(code: code, context: context()) }
        return code
    }
}

public struct EngineAError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}

let noPTS: Int64 = swift_AV_NOPTS_VALUE

// Disposition flags (libavformat/avformat.h). Defined here so we do not depend on macro import.
let dispositionDefault: Int32 = 0x0001
let dispositionComment: Int32 = 0x0008
let dispositionForced: Int32 = 0x0040
let dispositionVisualImpaired: Int32 = 0x0100

/// One demuxed packet, copied out of FFmpeg. Timestamps are in the stream's time base.
struct Packet: Sendable {
    var data: Data
    var pts: Int64
    var dts: Int64
    var duration: Int64
    var streamIndex: Int
    var isKey: Bool
}

/// Owned copy of AVCodecParameters plus the time base its timestamps use.
public final class CodecParameters: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<AVCodecParameters>
    let timeBase: AVRational

    init(copying source: UnsafePointer<AVCodecParameters>, timeBase: AVRational) throws {
        guard let pointer = avcodec_parameters_alloc() else { throw EngineAError("avcodec_parameters_alloc failed") }
        self.pointer = pointer
        self.timeBase = timeBase
        try FFmpegError.check(avcodec_parameters_copy(pointer, source), "avcodec_parameters_copy")
    }

    deinit {
        var p: UnsafeMutablePointer<AVCodecParameters>? = pointer
        avcodec_parameters_free(&p)
    }

    func copy() throws -> CodecParameters {
        try CodecParameters(copying: pointer, timeBase: timeBase)
    }

    var codecID: AVCodecID { pointer.pointee.codec_id }

    var extradata: [UInt8] {
        guard let data = pointer.pointee.extradata, pointer.pointee.extradata_size > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(pointer.pointee.extradata_size)))
    }

    var doviConfig: DoviConfig? {
        guard let side = av_packet_side_data_get(pointer.pointee.coded_side_data, pointer.pointee.nb_coded_side_data,
                                                 AV_PKT_DATA_DOVI_CONF) else { return nil }
        let record = side.pointee.data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
        return DoviConfig(profile: Int(record.dv_profile), level: Int(record.dv_level),
                          blSignalCompatibilityID: Int(record.dv_bl_signal_compatibility_id),
                          rpuPresent: record.rpu_present_flag != 0, elPresent: record.el_present_flag != 0)
    }

    /// Test seam and P7/P8 handling: attach a Dolby Vision configuration record.
    func attachDolbyVision(profile: Int, level: Int, compatibilityID: Int) {
        removeDolbyVision()
        var size = 0
        guard let record = av_dovi_alloc(&size) else { return }
        record.pointee.dv_version_major = 1
        record.pointee.dv_version_minor = 0
        record.pointee.dv_profile = UInt8(profile)
        record.pointee.dv_level = UInt8(level)
        record.pointee.rpu_present_flag = 1
        record.pointee.el_present_flag = profile == 7 ? 1 : 0
        record.pointee.bl_present_flag = 1
        record.pointee.dv_bl_signal_compatibility_id = UInt8(compatibilityID)
        if av_packet_side_data_add(&pointer.pointee.coded_side_data, &pointer.pointee.nb_coded_side_data,
                                   AV_PKT_DATA_DOVI_CONF, record, size, 0) == nil {
            av_free(record)
        }
    }

    func removeDolbyVision() {
        av_packet_side_data_remove(pointer.pointee.coded_side_data, &pointer.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
    }
}

/// Runs blocking FFmpeg and network work on GCD threads, never on the Swift concurrency pool.
enum Blocking {
    static func run<T: Sendable>(on queue: DispatchQueue = .global(qos: .userInitiated),
                                 _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

func cString(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

func metadataValue(_ dictionary: OpaquePointer?, _ key: String) -> String? {
    guard let entry = av_dict_get(dictionary, key, nil, 0) else { return nil }
    return cString(entry.pointee.value)
}

func seconds(_ timestamp: Int64, _ timeBase: AVRational) -> Double {
    Double(timestamp) * Double(timeBase.num) / Double(timeBase.den)
}

func rescale(_ value: Int64, from: AVRational, to: AVRational) -> Int64 {
    av_rescale_q(value, from, to)
}
