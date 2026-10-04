import Foundation

public enum YesNoNA: String, Codable, Sendable, CaseIterable {
    case yes, no, notApplicable

    public var title: String {
        switch self {
        case .yes: "Yes"
        case .no: "No"
        case .notApplicable: "Not applicable"
        }
    }
}

public enum SubtitleOutcome: String, Codable, Sendable, CaseIterable {
    case yes, degraded, no, notApplicable

    public var title: String {
        switch self {
        case .yes: "Yes"
        case .degraded: "Degraded"
        case .no: "No"
        case .notApplicable: "Not applicable"
        }
    }
}

public enum DriftOutcome: String, Codable, Sendable, CaseIterable {
    case none, slight, bad

    public var title: String {
        switch self {
        case .none: "None"
        case .slight: "Slight"
        case .bad: "Bad"
        }
    }
}

/// Native tvOS player features that Engine A must keep (P0 checklist).
public enum NativeFeature: String, Codable, Sendable, CaseIterable {
    case transportBar, infoPanelTracks, chapters, siriRewind, scrubThumbnails, pip

    public var title: String {
        switch self {
        case .transportBar: "Transport bar"
        case .infoPanelTracks: "Info panel tracks"
        case .chapters: "Chapters"
        case .siriRewind: "Siri rewind"
        case .scrubThumbnails: "Scrub thumbnails"
        case .pip: "Picture in picture"
        }
    }
}

/// What the owner saw on the TV and receiver. Filled in after each run.
public struct HarnessObservations: Codable, Sendable, Equatable {
    public var dynamicRangeSwitch: YesNoNA?
    public var atmos: YesNoNA?
    public var subtitles: SubtitleOutcome?
    public var nativeFeatures: [NativeFeature]
    public var drift: DriftOutcome?
    public var notes: String

    public init(dynamicRangeSwitch: YesNoNA? = nil, atmos: YesNoNA? = nil, subtitles: SubtitleOutcome? = nil,
                nativeFeatures: [NativeFeature] = [], drift: DriftOutcome? = nil, notes: String = "") {
        self.dynamicRangeSwitch = dynamicRangeSwitch
        self.atmos = atmos
        self.subtitles = subtitles
        self.nativeFeatures = nativeFeatures
        self.drift = drift
        self.notes = notes
    }

    public mutating func toggle(_ feature: NativeFeature) {
        if let index = nativeFeatures.firstIndex(of: feature) {
            nativeFeatures.remove(at: index)
        } else {
            nativeFeatures.append(feature)
            nativeFeatures.sort { $0.rawValue < $1.rawValue }
        }
    }
}

public struct Reroute: Codable, Sendable, Equatable {
    public var from: EngineID
    public var reason: RouteReason
    public var atSeconds: Double

    public init(from: EngineID, reason: RouteReason, atSeconds: Double) {
        self.from = from
        self.reason = reason
        self.atSeconds = atSeconds
    }
}

/// One play or seek-test run. Contains no URLs and no keys: free text is scrubbed again on export.
public struct HarnessRun: Codable, Sendable, Identifiable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case play, seekTest
    }

    public var id: UUID
    public var date: Date
    public var fileName: String
    public var mode: Mode
    /// Engine forced by the Play A or Play C button. Nil for Play Auto.
    public var requested: EngineID?
    public var probeSummary: String?
    public var probe: StreamProbe?
    /// The decision from `prepare`, before any reroute.
    public var decision: RoutingDecision
    /// Nil when the run failed before any engine started.
    public var enginePlayed: EngineID?
    public var reroutes: [Reroute]
    public var prepareMillis: Int
    /// First frame of the engine that ended up playing, measured from its session creation.
    public var ttffMillis: Int?
    public var seekLatenciesMillis: [Int]
    public var seekTimeouts: Int
    public var seekMedianMillis: Double?
    public var seekP90Millis: Double?
    public var peakMemoryMB: Double?
    public var playedSeconds: Double?
    public var diagnostics: PlaybackDiagnostics?
    public var failure: String?
    public var notes: [String]
    public var observations: HarnessObservations?

    public init(id: UUID = UUID(), date: Date = Date(), fileName: String, mode: Mode, requested: EngineID?,
                probeSummary: String?, probe: StreamProbe?, decision: RoutingDecision, enginePlayed: EngineID?,
                prepareMillis: Int) {
        self.id = id
        self.date = date
        self.fileName = fileName
        self.mode = mode
        self.requested = requested
        self.probeSummary = probeSummary
        self.probe = probe
        self.decision = decision
        self.enginePlayed = enginePlayed
        self.reroutes = []
        self.prepareMillis = prepareMillis
        self.seekLatenciesMillis = []
        self.seekTimeouts = 0
        self.notes = []
    }

    public mutating func recordSeeks(latencies: [Int], timeouts: Int) {
        seekLatenciesMillis = latencies
        seekTimeouts = timeouts
        let values = latencies.map(Double.init)
        seekMedianMillis = Stats.median(values)
        seekP90Millis = Stats.percentile(values, 90)
    }

    func scrubbed(_ scrub: (String) -> String) -> HarnessRun {
        var run = self
        run.fileName = scrub(fileName)
        run.probeSummary = probeSummary.map(scrub)
        run.failure = failure.map(scrub)
        run.notes = notes.map(scrub)
        run.observations?.notes = observations.map { scrub($0.notes) } ?? ""
        run.diagnostics?.extra = (diagnostics?.extra ?? [:]).mapValues(scrub)
        if var probe = probe {
            probe.audio = probe.audio.map { track in
                var track = track
                track.title = track.title.map(scrub)
                return track
            }
            probe.subtitles = probe.subtitles.map { track in
                var track = track
                track.title = track.title.map(scrub)
                return track
            }
            probe.chapters = probe.chapters.map { chapter in
                var chapter = chapter
                chapter.title = chapter.title.map(scrub)
                return chapter
            }
            run.probe = probe
        }
        return run
    }
}

/// The document served at `/p0/results.json` and stored in Caches.
public struct HarnessExport: Codable, Sendable, Equatable {
    public var schema: Int
    public var generatedAt: Date
    public var runs: [HarnessRun]

    /// - Parameter scrub: applied to every free-text field (file names, notes, errors, track titles).
    ///   The app passes `Redactor.text` with the TorBox key as a secret.
    public static func json(runs: [HarnessRun], now: Date = Date(), scrub: (String) -> String) -> Data {
        let export = HarnessExport(schema: 1, generatedAt: now, runs: runs.map { $0.scrubbed(scrub) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Encoding plain Codable values cannot fail.
        return (try? encoder.encode(export)) ?? Data("{}".utf8)
    }

    public static func decode(_ data: Data) throws -> HarnessExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HarnessExport.self, from: data)
    }
}

/// The same random seek positions for every engine, so A and C are compared on equal footing.
public enum SeekPlan {
    public static let defaultSeed: UInt64 = 0x4C41_4E54
    public static let range: ClosedRange<Double> = 0.05...0.90

    public static func fractions(count: Int = 10, seed: UInt64 = defaultSeed) -> [Double] {
        var generator = SplitMix64(seed: seed)
        return (0..<count).map { _ in Double.random(in: range, using: &generator) }
    }

    public static func positions(duration: Double, count: Int = 10, seed: UInt64 = defaultSeed) -> [Double] {
        fractions(count: count, seed: seed).map { $0 * duration }
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
