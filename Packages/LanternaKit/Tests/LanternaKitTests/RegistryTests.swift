import Foundation
import Testing
@testable import LanternaKit

private struct FakeSource: MediaSource {
    let id = SourceID()
    let kind: SourceKind
    let displayName: String
    let capabilities: SourceCapabilities = [.streams]
    var result: Result<[StreamCandidate], SourceError>
    var delay: Duration = .zero

    func streams(for request: StreamRequest) async throws -> [StreamCandidate] {
        try await Task.sleep(for: delay)
        return try result.get()
    }
}

private func candidate(_ source: any MediaSource, _ name: String, resolution: Resolution? = .r1080, hdr: Set<HDRFormat> = [], atmos: Bool = false,
                       size: Int64 = 1_000_000_000, cached: Bool? = true, availability: StreamCandidate.Availability = .playable) -> StreamCandidate {
    var format = ClaimedFormat()
    format.resolution = resolution
    format.hdr = hdr
    format.hasAtmos = atmos
    return StreamCandidate(id: "\(source.id.rawValue):\(name)", sourceID: source.id, sourceKind: source.kind, title: .movie(tmdbID: 1, imdbID: "tt1"),
                           displayName: name, sizeBytes: size, claimed: format, isCached: cached, availability: availability, locatorHint: .url(URL(string: "https://x/\(name)")!))
}

struct RegistryTests {
    let request = StreamRequest(title: .movie(tmdbID: 1, imdbID: "tt1"))

    @Test func fansOutAndCollectsPerSourceFailures() async {
        var good = FakeSource(kind: .aiostreams, displayName: "A", result: .success([]))
        good.result = .success([candidate(good, "one")])
        let bad = FakeSource(kind: .torbox, displayName: "T", result: .failure(.needsCredentials))
        let registry = SourceRegistry(sources: [good, bad], timeout: 5)
        let progress = ProgressLog()
        let outcome = await registry.streams(for: request) { checked, total in progress.add(checked, total) }
        #expect(outcome.candidates.map(\.displayName) == ["one"])
        #expect(outcome.failures[bad.id] == .needsCredentials)
        #expect(progress.last == [2, 2])
    }

    @Test func slowSourcesTimeOutWithoutBlockingOthers() async {
        var fast = FakeSource(kind: .jellyfin, displayName: "J", result: .success([]))
        fast.result = .success([candidate(fast, "fast")])
        let slow = FakeSource(kind: .aiostreams, displayName: "A", result: .success([]), delay: .seconds(30))
        let registry = SourceRegistry(sources: [fast, slow], timeout: 0.2)
        let started = Date()
        let outcome = await registry.streams(for: request) { _, _ in }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(outcome.candidates.count == 1)
        if case .unreachable = outcome.failures[slow.id] {} else { Issue.record("expected timeout failure") }
    }

    @Test func failingSourceEntersCooldown() async {
        let flaky = FakeSource(kind: .aiostreams, displayName: "A", result: .failure(.unreachable("down")))
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000))
        let registry = SourceRegistry(sources: [flaky], timeout: 1, failureLimit: 2, cooldown: 120, now: { clock.date })
        for _ in 0..<2 { _ = await registry.streams(for: request) { _, _ in } }
        #expect(await registry.isCoolingDown(flaky.id))
        clock.date = clock.date.addingTimeInterval(121)
        #expect(await !registry.isCoolingDown(flaky.id))
    }
}

struct SelectorTests {
    let a = FakeSourceStub(kind: .aiostreams)
    let j = FakeSourceStub(kind: .jellyfin)

    struct FakeSourceStub { let kind: SourceKind; let id = SourceID() }

    private func make(_ stub: FakeSourceStub, _ name: String, resolution: Resolution = .r1080, hdr: Set<HDRFormat> = [], atmos: Bool = false,
                      size: Int64 = 1_000_000_000, cached: Bool? = true, availability: StreamCandidate.Availability = .playable) -> StreamCandidate {
        var format = ClaimedFormat()
        format.resolution = resolution
        format.hdr = hdr
        format.hasAtmos = atmos
        return StreamCandidate(id: "\(stub.id.rawValue):\(name)", sourceID: stub.id, sourceKind: stub.kind, title: .movie(tmdbID: 1, imdbID: "tt1"),
                               displayName: name, sizeBytes: size, claimed: format, isCached: cached, availability: availability, locatorHint: .url(URL(string: "https://x/\(name)")!))
    }

    @Test func qualityRankingPrefersResolutionThenHDRThenAtmos() {
        let list = [make(a, "1080"), make(a, "4k", resolution: .r2160), make(a, "4kdv", resolution: .r2160, hdr: [.dolbyVision], atmos: true), make(a, "4khdr", resolution: .r2160, hdr: [.hdr10])]
        var prefs = StreamPrefs()
        prefs.preferLibrary = false
        #expect(StreamSelector.rank(list, prefs: prefs).map(\.displayName) == ["4kdv", "4khdr", "4k", "1080"])
    }

    @Test func libraryComesFirstWhenPreferred() {
        let list = [make(a, "aio4k", resolution: .r2160), make(j, "jf1080")]
        var prefs = StreamPrefs()
        prefs.preferLibrary = true
        #expect(StreamSelector.rank(list, prefs: prefs).first?.displayName == "jf1080")
        prefs.preferLibrary = false
        #expect(StreamSelector.rank(list, prefs: prefs).first?.displayName == "aio4k")
    }

    @Test func filtersApplyRequirements() {
        let list = [make(a, "sd", resolution: .r480), make(a, "dv", resolution: .r2160, hdr: [.dolbyVision]), make(a, "big", resolution: .r2160, size: 90_000_000_000)]
        var prefs = StreamPrefs()
        prefs.minResolution = .r1080
        prefs.requireDolbyVision = true
        #expect(StreamSelector.filter(list, prefs: prefs).map(\.displayName) == ["dv"])
        prefs.requireDolbyVision = false
        prefs.maxSizeGB = 50
        #expect(StreamSelector.filter(list, prefs: prefs).map(\.displayName) == ["dv"])
    }

    @Test func autoSelectSkipsUnavailableAndUncachedWhenACachedOneExists() {
        let list = [make(a, "gone", resolution: .r2160, availability: .unavailable("expired")),
                    make(a, "uncached4k", resolution: .r2160, cached: false),
                    make(a, "cached1080", cached: true)]
        let pick = StreamSelector.autoSelect(list, prefs: StreamPrefs(), remembered: nil)
        #expect(pick?.displayName == "cached1080")
        #expect(StreamSelector.autoSelect([list[0]], prefs: StreamPrefs(), remembered: nil) == nil)
    }

    @Test func rememberedChoiceWinsWhenStillPresent() {
        let list = [make(a, "best", resolution: .r2160), make(a, "remembered")]
        let pick = StreamSelector.autoSelect(list, prefs: StreamPrefs(), remembered: list[1].id)
        #expect(pick?.displayName == "remembered")
    }

    @Test func groupingFollowsSourceOrder() {
        let list = [make(a, "x"), make(j, "y")]
        var prefs = StreamPrefs()
        prefs.sourceOrder = [.jellyfin, .aiostreams]
        #expect(StreamSelector.grouped(list, prefs: prefs).map(\.kind) == [.jellyfin, .aiostreams])
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[Int]] = []
    func add(_ a: Int, _ b: Int) { lock.withLock { items.append([a, b]) } }
    var last: [Int]? { lock.withLock { items.last } }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
