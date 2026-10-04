import Foundation

public struct StreamSearchOutcome: Sendable {
    public var candidates: [StreamCandidate]
    public var failures: [SourceID: SourceError]
}

/// Fans stream lookups out across enabled sources with a per-source timeout and a cooldown after repeated failures.
public actor SourceRegistry {
    private(set) var sources: [any MediaSource]
    let timeout: TimeInterval
    let failureLimit: Int
    let cooldown: TimeInterval
    let now: @Sendable () -> Date
    private var failureCounts: [SourceID: Int] = [:]
    private var coolingUntil: [SourceID: Date] = [:]

    public init(sources: [any MediaSource], timeout: TimeInterval = 20, failureLimit: Int = 3, cooldown: TimeInterval = 120,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.sources = sources
        self.timeout = timeout
        self.failureLimit = failureLimit
        self.cooldown = cooldown
        self.now = now
    }

    public func setSources(_ sources: [any MediaSource]) { self.sources = sources }

    public func sources(of kind: SourceKind) -> [any MediaSource] { sources.filter { $0.kind == kind } }

    public func sources(with capability: SourceCapabilities) -> [any MediaSource] { sources.filter { $0.capabilities.contains(capability) } }

    public func isCoolingDown(_ id: SourceID) -> Bool {
        guard let until = coolingUntil[id] else { return false }
        if now() >= until {
            coolingUntil[id] = nil
            failureCounts[id] = 0
            return false
        }
        return true
    }

    private func record(_ id: SourceID, success: Bool) {
        if success {
            failureCounts[id] = 0
            return
        }
        failureCounts[id, default: 0] += 1
        if failureCounts[id, default: 0] >= failureLimit { coolingUntil[id] = now().addingTimeInterval(cooldown) }
    }

    /// `onProgress` receives (checked, total) as each source finishes: the "checked n of m" overlay.
    public func streams(for request: StreamRequest, onProgress: @escaping @Sendable (Int, Int) -> Void) async -> StreamSearchOutcome {
        let active = sources.filter { $0.capabilities.contains(.streams) || $0.capabilities.contains(.library) }
        let timeout = timeout
        var candidates: [StreamCandidate] = []
        var failures: [SourceID: SourceError] = [:]
        var checked = 0
        let total = active.count

        let eligible = active.filter { !isCoolingDown($0.id) }
        for source in active where !eligible.contains(where: { $0.id == source.id }) {
            failures[source.id] = .rateLimited(retryAfter: coolingUntil[source.id].map { $0.timeIntervalSince(now()) })
            checked += 1
        }
        if checked > 0 { onProgress(checked, total) }

        await withTaskGroup(of: (SourceID, Result<[StreamCandidate], SourceError>).self) { group in
            for source in eligible {
                group.addTask {
                    do {
                        let result = try await Self.withTimeout(timeout) { try await source.streams(for: request) }
                        return (source.id, .success(result))
                    } catch let error as SourceError {
                        return (source.id, .failure(error))
                    } catch {
                        return (source.id, .failure(.unreachable("lookup failed")))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let found):
                    candidates += found
                    record(id, success: true)
                case .failure(let error):
                    // A source with nothing to offer for this title is not unhealthy.
                    if error == .unsupported || error == .notFound { record(id, success: true) } else { failures[id] = error; record(id, success: false) }
                }
                checked += 1
                onProgress(checked, total)
            }
        }
        return StreamSearchOutcome(candidates: candidates, failures: failures)
    }

    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SourceError.unreachable("timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Filtering, ranking and auto-select for the stream picker.
public enum StreamSelector {
    public static func filter(_ candidates: [StreamCandidate], prefs: StreamPrefs) -> [StreamCandidate] {
        candidates.filter { candidate in
            if let min = prefs.minResolution, (candidate.claimed.resolution ?? .r480) < min { return false }
            if prefs.requireDolbyVision, !candidate.claimed.hdr.contains(.dolbyVision) { return false }
            if prefs.requireAtmos, !candidate.claimed.hasAtmos { return false }
            if let max = prefs.maxSizeGB, let size = candidate.sizeBytes, size > Int64(max) * 1_000_000_000 { return false }
            return true
        }
    }

    static func qualityScore(_ candidate: StreamCandidate) -> Int {
        var score = (candidate.claimed.resolution?.rawValue ?? 0) * 10
        if candidate.claimed.hdr.contains(.dolbyVision) { score += 400 }
        else if !candidate.claimed.hdr.isEmpty { score += 250 }
        if candidate.claimed.hasAtmos { score += 100 }
        if candidate.claimed.source == "REMUX" { score += 50 }
        return score
    }

    public static func rank(_ candidates: [StreamCandidate], prefs: StreamPrefs) -> [StreamCandidate] {
        func sourceIndex(_ kind: SourceKind) -> Int { prefs.sourceOrder.firstIndex(of: kind) ?? prefs.sourceOrder.count }
        func isLibrary(_ c: StreamCandidate) -> Bool { c.sourceKind == .jellyfin || c.sourceKind == .torbox }
        return candidates.sorted { lhs, rhs in
            if prefs.preferLibrary, isLibrary(lhs) != isLibrary(rhs) { return isLibrary(lhs) }
            switch prefs.sort {
            case .cachedFirst:
                if (lhs.isCached ?? false) != (rhs.isCached ?? false) { return lhs.isCached ?? false }
            case .size:
                if (lhs.sizeBytes ?? 0) != (rhs.sizeBytes ?? 0) { return (lhs.sizeBytes ?? 0) > (rhs.sizeBytes ?? 0) }
            case .quality:
                break
            }
            let (l, r) = (qualityScore(lhs), qualityScore(rhs))
            if l != r { return l > r }
            if sourceIndex(lhs.sourceKind) != sourceIndex(rhs.sourceKind) { return sourceIndex(lhs.sourceKind) < sourceIndex(rhs.sourceKind) }
            return (lhs.sizeBytes ?? 0) > (rhs.sizeBytes ?? 0)
        }
    }

    /// Picks the best playable stream. A cached or owned stream beats an uncached one even at lower quality.
    public static func autoSelect(_ candidates: [StreamCandidate], prefs: StreamPrefs, remembered: String?) -> StreamCandidate? {
        let playable = candidates.filter { $0.availability == .playable }
        if let remembered, let hit = playable.first(where: { $0.id == remembered }) { return hit }
        let ranked = rank(filter(playable, prefs: prefs), prefs: prefs)
        return ranked.first { $0.isCached != false } ?? ranked.first
    }

    public static func grouped(_ candidates: [StreamCandidate], prefs: StreamPrefs) -> [(kind: SourceKind, items: [StreamCandidate])] {
        let ranked = rank(candidates, prefs: prefs)
        var result: [(kind: SourceKind, items: [StreamCandidate])] = []
        let kinds = prefs.sourceOrder + SourceKind.allCases.filter { !prefs.sourceOrder.contains($0) }
        for kind in kinds {
            let items = ranked.filter { $0.sourceKind == kind }
            if !items.isEmpty { result.append((kind, items)) }
        }
        return result
    }
}
