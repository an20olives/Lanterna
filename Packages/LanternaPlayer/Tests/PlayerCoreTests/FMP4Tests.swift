import Foundation
import Testing
@testable import PlayerCore

struct FMP4FragmentWriterTests {
    let samples = [
        FMP4Sample(data: Data([1, 2, 3]), duration: 3754, compositionOffset: 3754, isSync: true),
        FMP4Sample(data: Data([4, 5]), duration: 3754, compositionOffset: -3754, isSync: false),
    ]

    @Test func writesMoofThenMdat() throws {
        let bytes = FMP4FragmentWriter.fragment(sequenceNumber: 7, baseMediaDecodeTime: 900_000, samples: samples)
        let top = try MP4Box.parse(bytes)
        #expect(top.map(\.type) == ["moof", "mdat"])
        #expect(top[1].payload == Data([1, 2, 3, 4, 5]))
    }

    @Test func tfdtCarriesAbsoluteDecodeTime() throws {
        let bytes = FMP4FragmentWriter.fragment(sequenceNumber: 1, baseMediaDecodeTime: 123_456_789_000, samples: samples)
        let tfdt = try #require(try MP4Box.find(path: ["moof", "traf", "tfdt"], in: bytes))
        #expect(tfdt.payload.first == 1) // version 1, 64-bit time
        #expect(tfdt.payload.readUInt64(at: 4) == 123_456_789_000)
    }

    @Test func mfhdCarriesSequenceNumber() throws {
        let bytes = FMP4FragmentWriter.fragment(sequenceNumber: 42, baseMediaDecodeTime: 0, samples: samples)
        let mfhd = try #require(try MP4Box.find(path: ["moof", "mfhd"], in: bytes))
        #expect(mfhd.payload.readUInt32(at: 4) == 42)
    }

    @Test func trunDataOffsetPointsAtFirstSampleByte() throws {
        let bytes = FMP4FragmentWriter.fragment(sequenceNumber: 1, baseMediaDecodeTime: 0, samples: samples)
        let trun = try #require(try MP4Box.find(path: ["moof", "traf", "trun"], in: bytes))
        let dataOffset = Int(Int32(bitPattern: trun.payload.readUInt32(at: 8)))
        #expect(bytes[bytes.startIndex + dataOffset] == 1)
    }

    @Test func trunHasPerSampleDurationSizeFlagsAndSignedCTS() throws {
        let bytes = FMP4FragmentWriter.fragment(sequenceNumber: 1, baseMediaDecodeTime: 0, samples: samples)
        let trun = try #require(try MP4Box.find(path: ["moof", "traf", "trun"], in: bytes))
        let p = trun.payload
        #expect(p[p.startIndex] == 1)                          // version 1: signed composition offsets
        #expect(p.readUInt32(at: 0) & 0x00FF_FFFF == 0x000F01) // offset + duration + size + flags + cts
        #expect(p.readUInt32(at: 4) == 2)                      // sample count
        // sample 0: duration, size, flags, cts
        #expect(p.readUInt32(at: 12) == 3754)
        #expect(p.readUInt32(at: 16) == 3)
        #expect(p.readUInt32(at: 20) == 0x0200_0000)           // sync: depends on nothing
        #expect(Int32(bitPattern: p.readUInt32(at: 24)) == 3754)
        #expect(p.readUInt32(at: 36) == 0x0101_0000)           // non-sync
        #expect(Int32(bitPattern: p.readUInt32(at: 40)) == -3754)
    }

    @Test func tfhdUsesDefaultBaseIsMoofForTrackOne() throws {
        let bytes = FMP4FragmentWriter.fragment(sequenceNumber: 1, baseMediaDecodeTime: 0, samples: samples)
        let tfhd = try #require(try MP4Box.find(path: ["moof", "traf", "tfhd"], in: bytes))
        #expect(tfhd.payload.readUInt32(at: 0) & 0x00FF_FFFF == 0x02_0000)
        #expect(tfhd.payload.readUInt32(at: 4) == 1)
    }
}

struct MP4BoxTests {
    @Test func extractsInitSegmentFromMuxerOutput() throws {
        var out = Data()
        out.append(MP4Box.make("ftyp", Data([0x69, 0x73, 0x6F, 0x35])))
        out.append(MP4Box.make("moov", MP4Box.make("mvhd", Data(count: 8))))
        out.append(MP4Box.make("moof", Data(count: 4)))
        out.append(MP4Box.make("mdat", Data(count: 4)))
        let initSeg = try MP4Box.initSegment(from: out)
        #expect(try MP4Box.parse(initSeg).map(\.type) == ["ftyp", "moov"])
    }

    @Test func readsMediaTimescaleFromMdhd() throws {
        var mdhd = Data([0, 0, 0, 0])               // version 0, flags
        mdhd.appendUInt32(0); mdhd.appendUInt32(0)  // creation, modification
        mdhd.appendUInt32(90_000)                   // timescale
        mdhd.appendUInt32(0)                        // duration
        let moov = MP4Box.make("moov", MP4Box.make("trak", MP4Box.make("mdia", MP4Box.make("mdhd", mdhd))))
        #expect(try MP4Box.mediaTimescale(initSegment: moov) == 90_000)
    }

    @Test func truncatedBoxThrows() {
        #expect(throws: MP4Box.ParseError.self) { try MP4Box.parse(Data([0, 0, 0, 20, 0x6D, 0x6F])) }
    }
}

struct Dec3PatchTests {
    /// dec3 for one 5.1 independent substream with no dependent substreams, no JOC extension.
    func dec3Payload() -> Data { Data([0x0C, 0x00, 0x20, 0x0F, 0x00]) }

    func initWithDec3(_ payload: Data) -> Data {
        let ec3 = MP4Box.make("ec-3", Data(count: 28) + MP4Box.make("dec3", payload))
        let stsd = MP4Box.make("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + ec3)
        let tree = MP4Box.make("trak", MP4Box.make("mdia", MP4Box.make("minf", MP4Box.make("stbl", stsd))))
        return MP4Box.make("ftyp", Data(count: 4)) + MP4Box.make("moov", tree)
    }

    @Test func appendsJOCExtensionAndGrowsParents() throws {
        let original = initWithDec3(dec3Payload())
        let patched = try Dec3Patch.addJOCExtension(to: original, complexityIndex: 16)
        #expect(patched.count == original.count + 2)
        let dec3 = try #require(try MP4Box.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"], in: patched))
        #expect(dec3.payload.suffix(2) == Data([0x01, 16]))
        #expect(try MP4Box.parse(patched).map(\.type) == ["ftyp", "moov"])
    }

    @Test func leavesInitWithoutDec3Untouched() throws {
        let plain = MP4Box.make("ftyp", Data(count: 4)) + MP4Box.make("moov", MP4Box.make("mvhd", Data(count: 8)))
        #expect(try Dec3Patch.addJOCExtension(to: plain, complexityIndex: 16) == plain)
    }
}
