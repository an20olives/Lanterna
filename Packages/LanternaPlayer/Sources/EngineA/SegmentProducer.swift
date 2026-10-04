import FFmpegKit
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import PlayerCore

struct ProducedSegment: Sendable {
    var video: Data
    var audio: [Int: Data]
    var subtitles: [Int: String]
    var productionMillis: Int
}

public struct RemuxStats: Sendable, Codable {
    public var segmentsProduced = 0
    public var randomAccesses = 0
    public var totalProductionMillis = 0
    public var maxProductionMillis = 0
    public var prepareMillis = 0
    public var bytesFetched: Int64 = 0
    public var rangeRequests = 0

    public init() {}
}

/// Cuts segments out of the source with one demuxer. Every method runs on `queue`, one at a time.
///
/// Decode times are each segment's own sorted presentation times (signed composition offsets cover
/// reordering), so a segment is identical whether it was produced in order or straight after a seek.
final class SegmentProducer: @unchecked Sendable {
    struct AudioRendition {
        let index: Int
        let info: AudioTrackInfo
        let params: CodecParameters
        let transcoder: AudioTranscoder?
        var initSegment = Data()
        var timescale: Int32 = 48_000
        var codecString: String
        var channels: String
    }

    let queue = DispatchQueue(label: "lanterna.remux", qos: .userInitiated)
    let source: RemoteByteSource
    let probe: ProbeResult
    let decision: RoutingDecision
    let targetDuration: Double

    private(set) var plan = SegmentPlan(segments: [], targetDurationSeconds: 6)
    private(set) var videoInit = Data()
    private(set) var videoCodecs = ""
    private(set) var videoSupplementalCodecs: String?
    private(set) var audio: [Int: AudioRendition] = [:]
    private(set) var audioOrder: [Int] = []
    private(set) var subtitleTracks: [Int: SubtitleTrackInfo] = [:]
    private(set) var stats = RemuxStats()

    private var demuxer: Demuxer!
    private var videoIndex = 0
    private var videoParams: CodecParameters!
    private var videoTimescale: Int32 = 90_000
    private var isMP4 = false
    private var segmentStartTS: [Int64] = []
    private var origin: Int64 = 0
    private var streamTimeBase: [Int: AVRational] = [:]
    private var averageFrameDuration: Int64 = 1

    private var cursorNext = -1
    private var carry: [Packet] = []
    private var carryEncoded: [Int: [Packet]] = [:]
    private var longCues: [Int: [WebVTTCue]] = [:]

    init(source: RemoteByteSource, probe: ProbeResult, decision: RoutingDecision, targetDuration: Double) {
        self.source = source
        self.probe = probe
        self.decision = decision
        self.targetDuration = targetDuration
    }

    // MARK: - Prepare

    func prepare() throws {
        let started = Date()
        demuxer = try Demuxer(source: source)
        guard let video = demuxer.videoStreamIndex else { throw EngineAError("No video stream") }
        videoIndex = video
        isMP4 = { if case .mp4 = demuxer.kind { return true } else { return false } }()
        for i in 0..<demuxer.streamCount { streamTimeBase[i] = demuxer.stream(i).pointee.time_base }
        videoParams = try demuxer.parameters(video)

        let keyTS = demuxer.keyframeTimestamps(video)
        guard !keyTS.isEmpty else { throw EngineAError("No keyframe index") }
        let videoTB = streamTimeBase[video]!
        let keySeconds = keyTS.map { seconds($0, videoTB) }
        let lastKey = keySeconds.last ?? 0
        let duration = max(probe.probe.durationSeconds ?? lastKey + targetDuration, lastKey + 0.001)
        plan = SegmentPlanner(targetDuration: targetDuration).plan(keyframes: keySeconds, duration: duration)
        var byTime: [Double: Int64] = [:]
        for (s, ts) in zip(keySeconds, keyTS) { byTime[s] = ts }
        segmentStartTS = plan.segments.map { byTime[$0.start] ?? keyTS[0] }
        origin = segmentStartTS.first ?? 0

        let rate = demuxer.stream(video).pointee.avg_frame_rate
        if rate.num > 0, rate.den > 0 {
            averageFrameDuration = max(1, av_rescale_q(1, AVRational(num: rate.den, den: rate.num), videoTB))
        }

        try prepareVideo()
        try prepareAudio()
        for index in decision.webVTTTracks {
            if let info = probe.probe.subtitles.first(where: { $0.index == index }) { subtitleTracks[index] = info }
        }
        cursorNext = -1
        stats.prepareMillis = Int(Date().timeIntervalSince(started) * 1000)
    }

    private func prepareVideo() throws {
        videoInit = try InitSegmentBuilder.video(videoParams, treatment: decision.videoTreatment)
        videoTimescale = Int32(try MP4Box.mediaTimescale(initSegment: videoInit))
        let extradata = videoParams.extradata
        switch videoParams.codecID {
        case AV_CODEC_ID_HEVC:
            let dv = videoParams.doviConfig
            if case .dolbyVision(5) = decision.videoTreatment, let dv {
                videoCodecs = CodecString.dolbyVision(profile: 5, level: dv.level, tag: "dvh1")
            } else {
                videoCodecs = CodecString.hevc(hvcC: extradata, tag: "hvc1") ?? "hvc1.2.4.L150.90"
                if case .dolbyVision(8) = decision.videoTreatment, let dv {
                    videoSupplementalCodecs = CodecString.dolbyVisionSupplemental(
                        profile: 8, level: dv.level, compatibilityID: dv.blSignalCompatibilityID)
                }
            }
        case AV_CODEC_ID_H264:
            videoCodecs = CodecString.avc(avcC: extradata) ?? "avc1.640028"
        default:
            videoCodecs = "hvc1.2.4.L150.90"
        }
    }

    private func prepareAudio() throws {
        var needPackets: [Int: [Packet]] = [:]
        for plan in decision.audioPlan where plan.action != .drop {
            guard let info = probe.probe.audio.first(where: { $0.index == plan.trackIndex }) else { continue }
            let params = try demuxer.parameters(plan.trackIndex)
            let tb = streamTimeBase[plan.trackIndex]!
            var rendition: AudioRendition
            switch plan.action {
            case .transcode(let target):
                let originTS = av_rescale_q(origin, streamTimeBase[videoIndex]!, tb)
                let transcoder = try AudioTranscoder(source: params, target: target, originTimestamp: originTS)
                rendition = AudioRendition(index: plan.trackIndex, info: info, params: params, transcoder: transcoder,
                                           codecString: transcoder.codecString, channels: String(transcoder.outputChannels))
                rendition.initSegment = try InitSegmentBuilder.build(transcoder.encoderParameters, codecTag: 0, packets: [])
            default:
                rendition = AudioRendition(index: plan.trackIndex, info: info, params: params, transcoder: nil,
                                           codecString: Self.copyCodecString(info, params: params),
                                           channels: info.hasAtmos && info.codec == .eac3 ? "16/JOC" : String(info.channels))
                if InitSegmentBuilder.needsPackets(params.codecID) {
                    needPackets[plan.trackIndex] = []
                } else {
                    rendition.initSegment = try InitSegmentBuilder.build(params, codecTag: 0, packets: [])
                }
            }
            audio[plan.trackIndex] = rendition
            audioOrder.append(plan.trackIndex)
        }

        if !needPackets.isEmpty {
            try demuxer.seek(stream: videoIndex, to: origin)
            var reads = 0
            while reads < 4000, needPackets.values.contains(where: { $0.count < 8 }), let packet = try demuxer.readPacket() {
                reads += 1
                if needPackets[packet.streamIndex] != nil, needPackets[packet.streamIndex]!.count < 8 {
                    needPackets[packet.streamIndex]!.append(packet)
                }
            }
            for (index, packets) in needPackets {
                guard var rendition = audio[index] else { continue }
                var initSegment = try InitSegmentBuilder.build(rendition.params, codecTag: 0, packets: packets)
                if rendition.info.codec == .eac3, rendition.info.hasAtmos {
                    initSegment = try Dec3Patch.addJOCExtension(to: initSegment, complexityIndex: 16)
                }
                rendition.initSegment = initSegment
                audio[index] = rendition
            }
        }

        for (index, rendition) in audio {
            audio[index]?.timescale = Int32((try? MP4Box.mediaTimescale(initSegment: rendition.initSegment)) ?? 48_000)
        }
    }

    static func copyCodecString(_ info: AudioTrackInfo, params: CodecParameters) -> String {
        switch info.codec {
        case .aac: params.pointer.pointee.profile == 4 ? "mp4a.40.5" : "mp4a.40.2" // 4 = HE-AAC
        case .ac3: "ac-3"
        case .eac3: "ec-3"
        case .alac: "alac"
        default: "mp4a.40.2"
        }
    }

    // MARK: - Produce

    func produce(_ n: Int) throws -> ProducedSegment {
        let started = Date()
        guard plan.segments.indices.contains(n) else { throw EngineAError("No segment \(n)") }
        let segment = plan.segments[n]
        let startTS = segmentStartTS[n]
        let endTS: Int64? = n + 1 < segmentStartTS.count ? segmentStartTS[n + 1] : nil
        let isLast = endTS == nil

        var pending: [Packet]
        if cursorNext == n {
            pending = carry
        } else {
            try demuxer.seek(stream: videoIndex, to: startTS)
            pending = []
            carryEncoded = [:]
            longCues = [:]
            for rendition in audio.values { try rendition.transcoder?.reset() }
            stats.randomAccesses += 1
        }
        carry = []

        let audioIndices = Set(audio.keys)
        let subtitleIndices = Set(subtitleTracks.keys)
        var video: [Packet] = []
        var audioPackets: [Int: [Packet]] = [:]
        var subtitlePackets: [Int: [Packet]] = [:]
        var nextCarry: [Packet] = []
        var collecting = false
        var videoStopped = false
        var videoAfterStop = 0
        var audioDone = Set<Int>()
        var pendingIndex = 0

        func nextPacket() throws -> Packet? {
            if pendingIndex < pending.count {
                pendingIndex += 1
                return pending[pendingIndex - 1]
            }
            return try demuxer.readPacket()
        }

        while let packet = try nextPacket() {
            let index = packet.streamIndex
            if index == videoIndex {
                let key = isMP4 || packet.pts == noPTS ? packet.dts : packet.pts
                if videoStopped {
                    nextCarry.append(packet)
                    videoAfterStop += 1
                } else if !collecting {
                    if packet.isKey, key != noPTS, key >= startTS - 1 {
                        collecting = true
                        video.append(packet)
                    }
                } else if let endTS, packet.isKey, key != noPTS, key >= endTS - 1 {
                    videoStopped = true
                    videoAfterStop = 1
                    nextCarry.append(packet)
                } else {
                    video.append(packet)
                }
            } else if audioIndices.contains(index) || subtitleIndices.contains(index) {
                let time = packet.pts == noPTS ? nil : seconds(packet.pts, streamTimeBase[index]!)
                if let time, n > 0, time < segment.start - 0.0005 { continue } // belonged to the previous segment
                if isLast || time.map({ $0 < segment.end - 0.0005 }) ?? !videoStopped {
                    if audioIndices.contains(index) { audioPackets[index, default: []].append(packet) }
                    else { subtitlePackets[index, default: []].append(packet) }
                } else {
                    nextCarry.append(packet)
                    if audioIndices.contains(index) { audioDone.insert(index) }
                }
            }
            if videoStopped, videoAfterStop >= 8, audioDone.isSuperset(of: audioIndices) { break }
            if videoStopped, videoAfterStop > 480 { break }
        }
        if pendingIndex < pending.count { nextCarry.append(contentsOf: pending[pendingIndex...]) }
        cursorNext = n + 1
        carry = nextCarry

        let videoFragment = buildVideoFragment(n: n, packets: video, following: nextCarry)
        var audioFragments: [Int: Data] = [:]
        for index in audioOrder {
            audioFragments[index] = try buildAudioFragment(n: n, index: index, packets: audioPackets[index] ?? [],
                                                           endTS: endTS)
        }
        var vtt: [Int: String] = [:]
        for index in subtitleIndices {
            vtt[index] = buildSubtitles(index: index, packets: subtitlePackets[index] ?? [], segment: segment)
        }

        let millis = Int(Date().timeIntervalSince(started) * 1000)
        stats.segmentsProduced += 1
        stats.totalProductionMillis += millis
        stats.maxProductionMillis = max(stats.maxProductionMillis, millis)
        stats.bytesFetched = source.bytesFetched
        stats.rangeRequests = source.requestCount
        return ProducedSegment(video: videoFragment, audio: audioFragments, subtitles: vtt, productionMillis: millis)
    }

    private func buildVideoFragment(n: Int, packets: [Packet], following: [Packet]) -> Data {
        let tb = streamTimeBase[videoIndex]!
        let ts = AVRational(num: 1, den: videoTimescale)
        func r(_ value: Int64) -> Int64 { av_rescale_q(value - origin, tb, ts) }
        guard !packets.isEmpty else {
            return FMP4FragmentWriter.fragment(sequenceNumber: UInt32(n + 1), baseMediaDecodeTime: 0, samples: [])
        }
        let pts = packets.map { $0.pts == noPTS ? $0.dts : $0.pts }
        let decode = pts.sorted().map(r)
        let followingVideo = following.filter { $0.streamIndex == videoIndex }.prefix(8).map { $0.pts == noPTS ? $0.dts : $0.pts }
        let nextStart: Int64
        if let earliest = followingVideo.min() {
            nextStart = r(earliest)
        } else {
            let last: Int64 = pts.max() ?? 0
            var duration: Int64 = averageFrameDuration
            if let final = packets.last, final.duration > 0 { duration = final.duration }
            nextStart = r(last + duration)
        }
        let samples = packets.indices.map { i -> FMP4Sample in
            let end = i + 1 < decode.count ? decode[i + 1] : nextStart
            return FMP4Sample(data: packets[i].data, duration: UInt32(clamping: max(0, end - decode[i])),
                              compositionOffset: Int32(clamping: r(pts[i]) - decode[i]), isSync: packets[i].isKey)
        }
        return FMP4FragmentWriter.fragment(sequenceNumber: UInt32(n + 1),
                                           baseMediaDecodeTime: UInt64(max(0, decode[0])), samples: samples)
    }

    private func buildAudioFragment(n: Int, index: Int, packets: [Packet], endTS: Int64?) throws -> Data {
        guard let rendition = audio[index] else { return Data() }
        let outTB = AVRational(num: 1, den: rendition.timescale)
        var timed: [(time: Int64, duration: Int64, data: Data)] = []

        if let transcoder = rendition.transcoder {
            var encoded = carryEncoded[index] ?? []
            for packet in packets { encoded += try transcoder.feed(packet) }
            if endTS == nil { encoded += try transcoder.finish() }
            let end = endTS.map { av_rescale_q($0 - origin, streamTimeBase[videoIndex]!, transcoder.outputTimeBase) }
            let mine = encoded.filter { end == nil || $0.pts < end! }
            carryEncoded[index] = encoded.filter { end != nil && $0.pts >= end! }
            timed = mine.map {
                (av_rescale_q($0.pts, transcoder.outputTimeBase, outTB), av_rescale_q($0.duration, transcoder.outputTimeBase, outTB), $0.data)
            }
        } else {
            let tb = streamTimeBase[index]!
            let streamOrigin = av_rescale_q(origin, streamTimeBase[videoIndex]!, tb)
            let sorted = packets.filter { $0.pts != noPTS }.sorted { $0.pts < $1.pts }
            timed = sorted.map { (av_rescale_q($0.pts - streamOrigin, tb, outTB), av_rescale_q($0.duration, tb, outTB), $0.data) }
        }
        timed = timed.filter { $0.time >= 0 }
        let samples = timed.indices.map { i -> FMP4Sample in
            let duration = i + 1 < timed.count ? timed[i + 1].time - timed[i].time : timed[i].duration
            return FMP4Sample(data: timed[i].data, duration: UInt32(clamping: max(1, duration)), compositionOffset: 0, isSync: true)
        }
        return FMP4FragmentWriter.fragment(sequenceNumber: UInt32(n + 1),
                                           baseMediaDecodeTime: UInt64(timed.first?.time ?? 0), samples: samples)
    }

    private func buildSubtitles(index: Int, packets: [Packet], segment: Segment) -> String {
        guard let info = subtitleTracks[index], let tb = streamTimeBase[index] else { return WebVTT.segment(cues: []) }
        let originSeconds = seconds(origin, streamTimeBase[videoIndex]!)
        var cues = (longCues[index] ?? []).filter { $0.end > segment.start - originSeconds }
        for packet in packets where packet.pts != noPTS {
            let raw = String(decoding: packet.data, as: UTF8.self)
            let text: String?
            switch info.format {
            case .srt: text = WebVTT.cueText(fromSRT: raw)
            case .ass, .ssa: text = WebVTT.cueText(fromASSPacket: raw)
            case .movText: text = WebVTT.cueText(fromSRT: String(decoding: packet.data.dropFirst(2), as: UTF8.self))
            default: text = WebVTT.cueText(fromSRT: raw)
            }
            guard let text, !text.isEmpty else { continue }
            let start = seconds(packet.pts, tb) - originSeconds
            let end = start + (packet.duration > 0 ? seconds(packet.duration, tb) : 4)
            cues.append(WebVTTCue(start: start, end: end, text: text))
        }
        cues.sort { $0.start < $1.start }
        longCues[index] = cues.filter { $0.end > segment.end - originSeconds }
        return WebVTT.segment(cues: cues)
    }
}
