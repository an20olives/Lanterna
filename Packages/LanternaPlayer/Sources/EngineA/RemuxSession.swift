import Foundation
import os
import PlayerCore

/// Serializes production, de-duplicates requests, caches a few segments, and reads one ahead.
///
/// A request at or just past the producer's cursor continues sequentially (cheap: no seek). Anything
/// else is a seek. Subtitle and audio requests a little ahead of video therefore pull production
/// forward instead of triggering a seek.
actor SegmentCoordinator {
    private let producer: SegmentProducer
    private let segmentCount: Int
    private let capacity: Int
    private let readAhead: Int
    private var cache: [Int: ProducedSegment] = [:]
    private var inFlight: [Int: Task<ProducedSegment, Error>] = [:]
    private var tail: Task<Void, Never>?
    private var expectedNext = 0
    private var lastRequested = 0

    init(producer: SegmentProducer, segmentCount: Int, capacity: Int, readAhead: Int) {
        self.producer = producer
        self.segmentCount = segmentCount
        self.capacity = max(capacity, readAhead + 2)
        self.readAhead = readAhead
    }

    func segment(_ n: Int) async throws -> ProducedSegment {
        lastRequested = n
        if let cached = cache[n] {
            scheduleReadAhead(after: n)
            return cached
        }
        if inFlight[n] == nil {
            if n >= expectedNext, n <= expectedNext + 2 {
                for k in expectedNext...n where cache[k] == nil && inFlight[k] == nil { schedule(k) }
            } else {
                schedule(n)
            }
            expectedNext = n + 1
        }
        guard let task = inFlight[n] else {
            if let cached = cache[n] { return cached }
            throw EngineAError("Segment \(n) vanished")
        }
        let result = try await task.value
        scheduleReadAhead(after: n)
        return result
    }

    private func scheduleReadAhead(after n: Int) {
        guard readAhead > 0 else { return }
        for k in (n + 1)...(n + readAhead) where k < segmentCount && cache[k] == nil && inFlight[k] == nil && k == expectedNext {
            schedule(k)
            expectedNext = k + 1
        }
    }

    private func schedule(_ k: Int) {
        let previous = tail
        let producer = self.producer
        let task = Task<ProducedSegment, Error> {
            await previous?.value
            do {
                let result = try await Blocking.run(on: producer.queue) { try producer.produce(k) }
                store(k, result)
                return result
            } catch {
                inFlight[k] = nil
                throw error
            }
        }
        inFlight[k] = task
        tail = Task { _ = try? await task.value }
    }

    private func store(_ k: Int, _ segment: ProducedSegment) {
        inFlight[k] = nil
        cache[k] = segment
        while cache.count > capacity {
            guard let farthest = cache.keys.max(by: { abs($0 - lastRequested) < abs($1 - lastRequested) }) else { break }
            cache[farthest] = nil
        }
    }
}

/// Engine A: serves one stream as a VOD fMP4 HLS presentation on 127.0.0.1 for AVPlayer.
public final class RemuxSession: @unchecked Sendable {
    public struct Options: Sendable {
        public var segmentDuration: Double
        public var cacheSegments: Int
        public var readAheadSegments: Int

        public init(segmentDuration: Double = 6, cacheSegments: Int = 5, readAheadSegments: Int = 1) {
            self.segmentDuration = segmentDuration
            self.cacheSegments = cacheSegments
            self.readAheadSegments = readAheadSegments
        }
    }

    static let log = Logger(subsystem: "lanterna", category: "engineA")

    let producer: SegmentProducer
    let decision: RoutingDecision
    let options: Options
    private let token: String
    private var server: TinyHTTPServer?
    private var coordinator: SegmentCoordinator?
    private var masterPlaylist = ""

    public init(source: RemoteByteSource, probe: ProbeResult, decision: RoutingDecision, options: Options = Options()) throws {
        guard source.rangeSupported else { throw EngineAError("Engine A needs Range support") }
        self.producer = SegmentProducer(source: source, probe: probe, decision: decision, targetDuration: options.segmentDuration)
        self.decision = decision
        self.options = options
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Prepares init segments and the plan, starts the server, and returns the master playlist URL.
    public func start() async throws -> URL {
        let producer = self.producer
        try await Blocking.run(on: producer.queue) { try producer.prepare() }
        coordinator = SegmentCoordinator(producer: producer, segmentCount: producer.plan.segments.count,
                                         capacity: options.cacheSegments, readAhead: options.readAheadSegments)
        masterPlaylist = buildMaster()
        let server = TinyHTTPServer(bind: .loopback) { [weak self] head in
            await self?.respond(head) ?? .notFound()
        }
        let port = try await server.start()
        self.server = server
        Self.log.info("Engine A master playlist:\n\(self.masterPlaylist, privacy: .public)")
        let initBoxes = [ "colr", "mdcv", "clli", "hvcC", "dvcC", "dvvC", "pasp" ].filter { producer.videoInit.range(of: Data($0.utf8)) != nil }
        Self.log.info("Engine A video init boxes: \(initBoxes.joined(separator: ","), privacy: .public)")
        Self.log.info("Engine A session ready: \(producer.plan.segments.count) segments, prepare \(producer.stats.prepareMillis) ms")
        return URL(string: "http://127.0.0.1:\(port)/\(token)/master.m3u8")!
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    public func stats() async -> RemuxStats {
        let producer = self.producer
        return (try? await Blocking.run(on: producer.queue) { producer.stats }) ?? RemuxStats()
    }

    private func respond(_ head: HTTPRequestHead) async -> HTTPResponse {
        guard let route = LocalRoute(path: head.path, token: token), let coordinator else { return .notFound() }
        let playlist = "application/vnd.apple.mpegurl"
        do {
            switch route {
            case .master:
                return HTTPResponse(status: 200, contentType: playlist, body: Data(masterPlaylist.utf8))
            case .mediaPlaylist(.video), .mediaPlaylist(.audio):
                if case .mediaPlaylist(.audio(let i)) = route, producer.audio[i] == nil { return .notFound() }
                let text = PlaylistWriter.mediaPlaylist(plan: producer.plan, initURI: "init.mp4", segmentExtension: "m4s")
                return HTTPResponse(status: 200, contentType: playlist, body: Data(text.utf8))
            case .initSegment(.video):
                return HTTPResponse(status: 200, contentType: "video/mp4", body: producer.videoInit)
            case .initSegment(.audio(let i)):
                guard let rendition = producer.audio[i] else { return .notFound() }
                return HTTPResponse(status: 200, contentType: "audio/mp4", body: rendition.initSegment)
            case .segment(.video, let n):
                guard producer.plan.segments.indices.contains(n) else { return .notFound() }
                return HTTPResponse(status: 200, contentType: "video/mp4", body: try await coordinator.segment(n).video)
            case .segment(.audio(let i), let n):
                guard producer.audio[i] != nil, producer.plan.segments.indices.contains(n) else { return .notFound() }
                return HTTPResponse(status: 200, contentType: "audio/mp4", body: try await coordinator.segment(n).audio[i] ?? Data())
            case .subtitlePlaylist(let i):
                guard producer.subtitleTracks[i] != nil else { return .notFound() }
                let text = PlaylistWriter.mediaPlaylist(plan: producer.plan, initURI: nil, segmentExtension: "vtt")
                return HTTPResponse(status: 200, contentType: playlist, body: Data(text.utf8))
            case .subtitleSegment(let i, let n):
                guard producer.subtitleTracks[i] != nil, producer.plan.segments.indices.contains(n) else { return .notFound() }
                let text = try await coordinator.segment(n).subtitles[i] ?? WebVTT.segment(cues: [])
                return HTTPResponse(status: 200, contentType: "text/vtt", body: Data(text.utf8))
            }
        } catch {
            Self.log.error("Engine A request failed: \(String(describing: error), privacy: .public)")
            return HTTPResponse(status: 500, contentType: "text/plain", body: Data())
        }
    }

    private func buildMaster() -> String {
        let probe = producer.probe.probe
        let video = probe.video
        let range: VideoRange = {
            switch (video?.dynamicRange, decision.videoTreatment) {
            case (.hlg?, _): return .hlg
            case (.hdr10?, _), (.hdr10Plus?, _): return .pq
            case (.dolbyVision(let dv)?, let treatment):
                if dv.blSignalCompatibilityID == 4 { return .hlg }
                if dv.blSignalCompatibilityID == 2, treatment == .stripDolbyVision { return .sdr }
                return .pq
            default: return .sdr
            }
        }()
        let defaultAudio = producer.audioOrder.first { index in
            producer.audio[index]?.info.language.map { ["eng"].contains($0) } ?? false
        } ?? producer.audioOrder.first
        let audio = producer.audioOrder.compactMap { index -> MasterPlaylist.Audio? in
            guard let rendition = producer.audio[index] else { return nil }
            let info = rendition.info
            let name = info.title ?? [info.language?.uppercased(), info.codec.label + (info.hasAtmos ? " Atmos" : "")]
                .compactMap { $0 }.joined(separator: " ")
            return MasterPlaylist.Audio(id: index, name: name.isEmpty ? "Audio \(index)" : name, language: info.language,
                                        codecs: rendition.codecString, channels: rendition.channels,
                                        isDefault: index == defaultAudio, uri: "a/\(index)/index.m3u8")
        }
        let subtitles = producer.subtitleTracks.keys.sorted().compactMap { index -> MasterPlaylist.Subtitle? in
            guard let info = producer.subtitleTracks[index] else { return nil }
            let name = info.title ?? info.language?.uppercased() ?? "Subtitles \(index)"
            return MasterPlaylist.Subtitle(id: index, name: info.isForced ? "\(name) (Forced)" : name, language: info.language,
                                           isDefault: false, isForced: info.isForced, uri: "s/\(index)/index.m3u8")
        }
        let bandwidth = probe.bitRate ?? probe.contentLength.flatMap { length in
            probe.durationSeconds.map { Int(Double(length) * 8 / max($0, 1)) }
        } ?? 20_000_000
        let master = MasterPlaylist(
            video: .init(codecs: producer.videoCodecs, supplementalCodecs: producer.videoSupplementalCodecs,
                         width: video?.width ?? 1920, height: video?.height ?? 1080,
                         frameRate: video?.frameRate.value ?? 24, videoRange: range,
                         bandwidth: max(bandwidth, 1_000_000), uri: "v/index.m3u8"),
            audio: audio, subtitles: subtitles)
        return PlaylistWriter.masterPlaylist(master)
    }
}
