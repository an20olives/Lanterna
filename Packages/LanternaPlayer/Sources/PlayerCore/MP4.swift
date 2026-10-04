import Foundation

extension Data {
    /// Big-endian reads relative to `startIndex`, so they work on slices.
    func readUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func readUInt64(at offset: Int) -> UInt64 {
        UInt64(readUInt32(at: offset)) << 32 | UInt64(readUInt32(at: offset + 4))
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendUInt64(_ value: UInt64) {
        appendUInt32(UInt32(value >> 32))
        appendUInt32(UInt32(value & 0xFFFF_FFFF))
    }
}

/// Minimal ISO BMFF box reader and writer: enough to cut init segments out of FFmpeg's output,
/// read timescales, and patch dec3. Not a general MP4 parser.
public struct MP4Box: Sendable, Equatable {
    public enum ParseError: Error, Equatable {
        case truncated(at: Int)
        case missingMoov
        case missingBox(String)
    }

    public var type: String
    /// Box body without the size/type header.
    public var payload: Data

    /// Bytes to skip inside a container's payload before its child boxes begin.
    static let childOffsets: [String: Int] = [
        "moov": 0, "trak": 0, "mdia": 0, "minf": 0, "stbl": 0, "mvex": 0, "edts": 0, "dinf": 0,
        "moof": 0, "traf": 0, "stsd": 8,
        // Audio sample entries (ISO/IEC 14496-12 AudioSampleEntry).
        "ec-3": 28, "ac-3": 28, "mp4a": 28, "alac": 28, "fLaC": 28,
    ]

    public static func make(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.appendUInt32(UInt32(payload.count + 8))
        data.append(contentsOf: Array(type.utf8.prefix(4)))
        data.append(payload)
        return data
    }

    public static func parse(_ data: Data) throws -> [MP4Box] {
        var boxes: [MP4Box] = []
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= 8 else { throw ParseError.truncated(at: offset) }
            var size = Int(data.readUInt32(at: offset))
            var header = 8
            let typeStart = data.startIndex + offset + 4
            let type = String(decoding: data[typeStart..<typeStart + 4], as: UTF8.self)
            if size == 1 {
                guard data.count - offset >= 16 else { throw ParseError.truncated(at: offset) }
                size = Int(data.readUInt64(at: offset + 8))
                header = 16
            } else if size == 0 {
                size = data.count - offset
            }
            guard size >= header, offset + size <= data.count else { throw ParseError.truncated(at: offset) }
            let bodyStart = data.startIndex + offset + header
            boxes.append(MP4Box(type: type, payload: data[bodyStart..<data.startIndex + offset + size]))
            offset += size
        }
        return boxes
    }

    public static func children(of box: MP4Box) throws -> [MP4Box] {
        let skip = childOffsets[box.type] ?? 0
        guard box.payload.count >= skip else { throw ParseError.truncated(at: 0) }
        return try parse(box.payload.dropFirst(skip))
    }

    /// First box matching the path, descending through known containers.
    public static func find(path: [String], in data: Data) throws -> MP4Box? {
        guard let head = path.first else { return nil }
        var candidates = try parse(data).filter { $0.type == head }
        for type in path.dropFirst() {
            candidates = try candidates.flatMap { try children(of: $0) }.filter { $0.type == type }
        }
        return candidates.first
    }

    /// ftyp + moov out of a muxer's output that may also contain fragments.
    public static func initSegment(from muxerOutput: Data) throws -> Data {
        var result = Data()
        for box in try parse(muxerOutput) where box.type == "ftyp" || box.type == "moov" {
            result.append(make(box.type, box.payload))
        }
        guard try parse(result).contains(where: { $0.type == "moov" }) else { throw ParseError.missingMoov }
        return result
    }

    public static func mediaTimescale(initSegment: Data) throws -> UInt32 {
        guard let mdhd = try find(path: ["moov", "trak", "mdia", "mdhd"], in: initSegment) else {
            throw ParseError.missingBox("mdhd")
        }
        let version = mdhd.payload[mdhd.payload.startIndex]
        return mdhd.payload.readUInt32(at: version == 1 ? 20 : 12)
    }
}

public struct FMP4Sample: Sendable, Equatable {
    public var data: Data
    /// In the track's media timescale.
    public var duration: UInt32
    public var compositionOffset: Int32
    public var isSync: Bool

    public init(data: Data, duration: UInt32, compositionOffset: Int32, isSync: Bool) {
        self.data = data
        self.duration = duration
        self.compositionOffset = compositionOffset
        self.isSync = isSync
    }
}

/// Writes one moof+mdat for track 1. We write fragments ourselves (and take only the init segment
/// from FFmpeg) so that tfdt carries the absolute decode time of segments generated out of order.
public enum FMP4FragmentWriter {
    public static func fragment(sequenceNumber: UInt32, baseMediaDecodeTime: UInt64, samples: [FMP4Sample]) -> Data {
        var mfhd = Data([0, 0, 0, 0])
        mfhd.appendUInt32(sequenceNumber)

        var tfhd = Data([0, 0x02, 0, 0]) // default-base-is-moof
        tfhd.appendUInt32(1)

        var tfdt = Data([1, 0, 0, 0])
        tfdt.appendUInt64(baseMediaDecodeTime)

        // version 1 (signed CTS); data-offset, sample duration, size, flags, composition offset present.
        func trun(dataOffset: Int32) -> Data {
            var trun = Data([1, 0x00, 0x0F, 0x01])
            trun.appendUInt32(UInt32(samples.count))
            trun.appendUInt32(UInt32(bitPattern: dataOffset))
            for sample in samples {
                trun.appendUInt32(sample.duration)
                trun.appendUInt32(UInt32(sample.data.count))
                trun.appendUInt32(sample.isSync ? 0x0200_0000 : 0x0101_0000)
                trun.appendUInt32(UInt32(bitPattern: sample.compositionOffset))
            }
            return trun
        }

        func moof(dataOffset: Int32) -> Data {
            let traf = MP4Box.make("tfhd", tfhd) + MP4Box.make("tfdt", tfdt) + MP4Box.make("trun", trun(dataOffset: dataOffset))
            return MP4Box.make("moof", MP4Box.make("mfhd", mfhd) + MP4Box.make("traf", traf))
        }

        let moofSize = moof(dataOffset: 0).count
        var mdatPayload = Data(capacity: samples.reduce(0) { $0 + $1.data.count })
        for sample in samples { mdatPayload.append(sample.data) }
        return moof(dataOffset: Int32(moofSize + 8)) + MP4Box.make("mdat", mdatPayload)
    }
}

/// Adds the E-AC-3 JOC extension (flag_ec3_extension_type_a + complexity_index_type_a) to dec3.
/// FFmpeg 6.1's mov muxer does not write it, and Apple devices use it to recognize Atmos.
public enum Dec3Patch {
    public static func addJOCExtension(to initSegment: Data, complexityIndex: UInt8) throws -> Data {
        try rebuild(initSegment, complexityIndex: complexityIndex)
    }

    private static func rebuild(_ data: Data, complexityIndex: UInt8) throws -> Data {
        var output = Data()
        for box in try MP4Box.parse(data) {
            if box.type == "dec3" {
                var payload = Data(box.payload)
                if payload.count == baseLength(payload) { payload.append(contentsOf: [0x01, complexityIndex]) }
                output.append(MP4Box.make("dec3", payload))
            } else if let skip = MP4Box.childOffsets[box.type], box.payload.count >= skip {
                let prefix = box.payload.prefix(skip)
                let children = try rebuild(Data(box.payload.dropFirst(skip)), complexityIndex: complexityIndex)
                output.append(MP4Box.make(box.type, prefix + children))
            } else {
                output.append(MP4Box.make(box.type, box.payload))
            }
        }
        return output
    }

    /// Length of a dec3 body without the optional extension (ETSI TS 102 366 Annex F).
    static func baseLength(_ payload: Data) -> Int {
        guard payload.count >= 2 else { return -1 }
        let independent = Int(payload[payload.startIndex + 1] & 0x07) + 1
        var bitOffset = 16
        for _ in 0..<independent {
            // fscod 2, bsid 5, reserved 1, asvc 1, bsmod 3, acmod 3, lfeon 1, reserved 3 = 19 bits, then num_dep_sub 4.
            let numDep = bits(payload, at: bitOffset + 19, count: 4)
            bitOffset += 23 + (numDep > 0 ? 9 : 1)
        }
        return (bitOffset + 7) / 8
    }

    private static func bits(_ data: Data, at offset: Int, count: Int) -> Int {
        var value = 0
        for i in 0..<count {
            let bit = offset + i
            let byteIndex = data.startIndex + bit / 8
            guard byteIndex < data.endIndex else { return value }
            value = value << 1 | Int((data[byteIndex] >> (7 - UInt8(bit % 8))) & 1)
        }
        return value
    }
}
