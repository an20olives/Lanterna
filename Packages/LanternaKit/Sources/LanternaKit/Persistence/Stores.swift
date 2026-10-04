import Foundation
import SwiftData

public enum LanternaStore {
    /// tvOS purges everything but UserDefaults and Keychain, so the store lives in Caches there and is rebuilt when missing.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(SchemaV1.models, version: SchemaV1.versionIdentifier)
        if inMemory {
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appending(path: "Lanterna.store")
        do {
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        } catch {
            // A purged or unreadable store is a cache miss, not a crash.
            for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        }
    }
}

public struct ProgressSnapshot: Sendable, Equatable, Identifiable {
    public var titleKey: String
    public var showTMDBID: Int?
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var isCompleted: Bool
    public var syncState: String
    public var lastStreamID: String?
    public var updatedAt: Date
    public var id: String { titleKey }
    public var fraction: Double { durationSeconds > 0 ? positionSeconds / durationSeconds : 0 }
}

@ModelActor
public actor ProgressStore {
    public static let completionThreshold = 0.9

    private func fetch(_ key: String) -> PlaybackProgress? {
        try? modelContext.fetch(FetchDescriptor<PlaybackProgress>(predicate: #Predicate { $0.titleKey == key })).first
    }

    private func snapshot(_ row: PlaybackProgress) -> ProgressSnapshot {
        ProgressSnapshot(titleKey: row.titleKey, showTMDBID: row.showTMDBID, positionSeconds: row.positionSeconds, durationSeconds: row.durationSeconds,
                         isCompleted: row.isCompleted, syncState: row.syncStateRaw, lastStreamID: row.lastStreamID, updatedAt: row.updatedAt)
    }

    /// Local write on pause, stop or background. Marks the row pending until the outbox confirms it.
    public func record(titleKey: String, showTMDBID: Int?, position: Double, duration: Double, streamID: String?, deviceName: String, now: Date = Date()) {
        let row = fetch(titleKey) ?? {
            let new = PlaybackProgress(titleKey: titleKey, positionSeconds: position, durationSeconds: duration, deviceName: deviceName, updatedAt: now)
            modelContext.insert(new)
            return new
        }()
        row.showTMDBID = showTMDBID
        row.positionSeconds = position
        row.durationSeconds = duration
        row.isCompleted = duration > 0 && position / duration >= Self.completionThreshold
        row.syncStateRaw = "pending"
        row.lastStreamID = streamID ?? row.lastStreamID
        row.deviceName = deviceName
        row.updatedAt = now
        try? modelContext.save()
    }

    public func progress(for titleKey: String) -> ProgressSnapshot? { fetch(titleKey).map(snapshot) }

    public func markSynced(titleKey: String) {
        fetch(titleKey)?.syncStateRaw = "synced"
        try? modelContext.save()
    }

    /// Newest write wins, but a local pending row is pushed before it can be replaced.
    public func applyRemote(titleKey: String, showTMDBID: Int?, fraction: Double, duration: Double, at date: Date) {
        if let row = fetch(titleKey) {
            guard row.syncStateRaw != "pending", date > row.updatedAt else { return }
            row.positionSeconds = fraction * duration
            row.durationSeconds = duration
            row.isCompleted = fraction >= Self.completionThreshold
            row.syncStateRaw = "synced"
            row.updatedAt = date
        } else {
            let row = PlaybackProgress(titleKey: titleKey, positionSeconds: fraction * duration, durationSeconds: duration, deviceName: "trakt", updatedAt: date)
            row.showTMDBID = showTMDBID
            row.isCompleted = fraction >= Self.completionThreshold
            row.syncStateRaw = "synced"
            modelContext.insert(row)
        }
        try? modelContext.save()
    }

    /// Finished titles, newest first (local history until Trakt history is pulled).
    public func history(limit: Int) -> [ProgressSnapshot] {
        var descriptor = FetchDescriptor<PlaybackProgress>(predicate: #Predicate { $0.isCompleted },
                                                           sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map(snapshot)
    }

    /// The most recently touched episode of a show, finished or not.
    public func latestEpisode(forShow showID: Int) -> ProgressSnapshot? {
        var descriptor = FetchDescriptor<PlaybackProgress>(predicate: #Predicate { $0.showTMDBID == showID },
                                                           sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first.map(snapshot)
    }

    public func pending() -> [ProgressSnapshot] {
        let rows = (try? modelContext.fetch(FetchDescriptor<PlaybackProgress>(predicate: #Predicate { $0.syncStateRaw == "pending" }))) ?? []
        return rows.map(snapshot)
    }

    public func remove(titleKey: String) {
        if let row = fetch(titleKey) { modelContext.delete(row) }
        try? modelContext.save()
    }

    /// Dismisses an item from Continue Watching until `date` (about 30 days).
    public func hide(titleKey: String, until date: Date) {
        let kind = "hidden"
        let existing = try? modelContext.fetch(FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.kindRaw == kind && $0.titleKey == titleKey })).first
        let entry = existing ?? { let new = LibraryEntry(kindRaw: kind, titleKey: titleKey); modelContext.insert(new); return new }()
        entry.hiddenUntil = date
        entry.updatedAt = Date()
        try? modelContext.save()
    }

    /// Unfinished items, newest first, minus hidden ones. Episodes of one show collapse to the newest.
    public func continueWatching(limit: Int, now: Date = Date()) -> [ProgressSnapshot] {
        let rows = (try? modelContext.fetch(FetchDescriptor<PlaybackProgress>(predicate: #Predicate { !$0.isCompleted },
                                                                              sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        let hiddenKind = "hidden"
        let hidden = (try? modelContext.fetch(FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.kindRaw == hiddenKind }))) ?? []
        let hiddenKeys = Set(hidden.filter { ($0.hiddenUntil ?? .distantPast) > now }.map(\.titleKey))
        var seenShows = Set<Int>()
        var result: [ProgressSnapshot] = []
        for row in rows where !hiddenKeys.contains(row.titleKey) {
            if let show = row.showTMDBID, !seenShows.insert(show).inserted { continue }
            result.append(snapshot(row))
            if result.count == limit { break }
        }
        return result
    }
}

public struct OutboxEntry: Sendable, Equatable {
    public var idempotencyKey: String
    public var target: OutboxTarget
    public var op: String
    public var payload: Data
    public var attempts: Int
    public var createdAt: Date
}

public enum OutboxTarget: String, Sendable { case trakt, jellyfin }

@ModelActor
public actor OutboxStore {
    private func fetch(_ key: String) -> SyncOperation? {
        try? modelContext.fetch(FetchDescriptor<SyncOperation>(predicate: #Predicate { $0.idempotencyKey == key })).first
    }

    /// A repeated enqueue with the same key is ignored, so a retried stop cannot double-count.
    public func enqueue(idempotencyKey: String, target: OutboxTarget, op: String, payload: Data, now: Date = Date()) {
        guard fetch(idempotencyKey) == nil else { return }
        modelContext.insert(SyncOperation(idempotencyKey: idempotencyKey, targetRaw: target.rawValue, opRaw: op, payload: payload, now: now))
        try? modelContext.save()
    }

    public func due(now: Date = Date()) -> [OutboxEntry] {
        let rows = (try? modelContext.fetch(FetchDescriptor<SyncOperation>(predicate: #Predicate { $0.nextAttemptAt <= now },
                                                                           sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return rows.map { OutboxEntry(idempotencyKey: $0.idempotencyKey, target: OutboxTarget(rawValue: $0.targetRaw) ?? .trakt, op: $0.opRaw, payload: $0.payload, attempts: $0.attempts, createdAt: $0.createdAt) }
    }

    public func complete(idempotencyKey: String) {
        if let row = fetch(idempotencyKey) { modelContext.delete(row) }
        try? modelContext.save()
    }

    /// Exponential backoff: 10 s, 20 s, 40 s ... capped at one hour.
    public func fail(idempotencyKey: String, summary: String, now: Date = Date()) {
        guard let row = fetch(idempotencyKey) else { return }
        row.attempts += 1
        row.lastErrorSummary = summary
        row.nextAttemptAt = now.addingTimeInterval(min(10 * pow(2, Double(row.attempts - 1)), 3600))
        row.updatedAt = now
        try? modelContext.save()
    }

    public func count() -> Int { (try? modelContext.fetchCount(FetchDescriptor<SyncOperation>())) ?? 0 }
}

public enum LibraryKind: String, Sendable, CaseIterable { case watchlist, favorite, history, rating, hidden }

@ModelActor
public actor LibraryEntryStore {
    private func fetch(_ kind: LibraryKind, _ key: String) -> LibraryEntry? {
        let raw = kind.rawValue
        return try? modelContext.fetch(FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.kindRaw == raw && $0.titleKey == key && $0.playID == "" })).first
    }

    public func add(_ kind: LibraryKind, titleKey: String) {
        guard fetch(kind, titleKey) == nil else { return }
        modelContext.insert(LibraryEntry(kindRaw: kind.rawValue, titleKey: titleKey))
        try? modelContext.save()
    }

    public func remove(_ kind: LibraryKind, titleKey: String) {
        if let row = fetch(kind, titleKey) { modelContext.delete(row) }
        try? modelContext.save()
    }

    public func contains(_ kind: LibraryKind, titleKey: String) -> Bool { fetch(kind, titleKey) != nil }

    public func titleKeys(_ kind: LibraryKind) -> [String] {
        let raw = kind.rawValue
        let rows = (try? modelContext.fetch(FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.kindRaw == raw },
                                                                          sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        return rows.map(\.titleKey)
    }

    /// Replaces a kind with the remote list (Trakt is the single sync source).
    public func replace(_ kind: LibraryKind, with titleKeys: [String]) {
        let raw = kind.rawValue
        let rows = (try? modelContext.fetch(FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.kindRaw == raw }))) ?? []
        let keep = Set(titleKeys)
        for row in rows where !keep.contains(row.titleKey) { modelContext.delete(row) }
        let have = Set(rows.map(\.titleKey))
        for key in titleKeys where !have.contains(key) {
            let entry = LibraryEntry(kindRaw: raw, titleKey: key)
            entry.syncStateRaw = "synced"
            modelContext.insert(entry)
        }
        try? modelContext.save()
    }
}

@ModelActor
public actor CacheStore {
    public func save(_ detail: TitleDetail, now: Date = Date()) {
        let key = detail.summary.ref.key
        let data = try? JSONEncoder().encode(detail)
        let existing = try? modelContext.fetch(FetchDescriptor<TitleCache>(predicate: #Predicate { $0.titleKey == key })).first
        let row = existing ?? {
            let new = TitleCache(titleKey: key, tmdbID: detail.summary.ref.tmdbID, kindRaw: detail.summary.ref.kind.rawValue, title: detail.summary.title, fetchedAt: now)
            modelContext.insert(new)
            return new
        }()
        row.title = detail.summary.title
        row.imdbID = detail.summary.ref.imdbID
        row.year = detail.summary.year
        row.detailJSON = data
        row.fetchedAt = now
        row.updatedAt = now
        try? modelContext.save()
    }

    public func detail(for titleKey: String, maxAge: TimeInterval, now: Date = Date()) -> TitleDetail? {
        guard let row = try? modelContext.fetch(FetchDescriptor<TitleCache>(predicate: #Predicate { $0.titleKey == titleKey })).first,
              now.timeIntervalSince(row.fetchedAt) <= maxAge, let data = row.detailJSON else { return nil }
        return try? JSONDecoder().decode(TitleDetail.self, from: data)
    }

    /// Routing log (S29). Keeps the newest 500 rows.
    public func recordProbe(streamID: String, titleKey: String, probeJSON: Data, engine: String, reasons: [String], outcome: String,
                            failure: String?, now: Date = Date()) {
        let row = ProbeRecord(streamID: streamID, probeJSON: probeJSON, engineRaw: engine, reasons: reasons, outcomeRaw: outcome, probedAt: now)
        row.titleKey = titleKey
        row.failureSummary = failure
        modelContext.insert(row)
        let all = (try? modelContext.fetch(FetchDescriptor<ProbeRecord>(sortBy: [SortDescriptor(\.probedAt, order: .reverse)]))) ?? []
        for old in all.dropFirst(500) { modelContext.delete(old) }
        try? modelContext.save()
    }

    public struct ProbeLogEntry: Sendable, Identifiable {
        public var id: String
        public var titleKey: String?
        public var engine: String
        public var reasons: [String]
        public var outcome: String
        public var failure: String?
        public var probedAt: Date
        public var probeJSON: Data
    }

    public func recentProbes(limit: Int = 100) -> [ProbeLogEntry] {
        var descriptor = FetchDescriptor<ProbeRecord>(sortBy: [SortDescriptor(\.probedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.map { ProbeLogEntry(id: "\($0.streamID)-\($0.probedAt.timeIntervalSince1970)", titleKey: $0.titleKey, engine: $0.engineRaw, reasons: $0.reasons,
                                        outcome: $0.outcomeRaw, failure: $0.failureSummary, probedAt: $0.probedAt, probeJSON: $0.probeJSON) }
    }

    public func saveAvailability(titleKey: String, region: String, offers: [ProviderOffer], now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(offers) else { return }
        let existing = try? modelContext.fetch(FetchDescriptor<WatchAvailability>(predicate: #Predicate { $0.titleKey == titleKey && $0.region == region })).first
        if let existing {
            existing.offersJSON = data; existing.fetchedAt = now; existing.updatedAt = now
        } else {
            modelContext.insert(WatchAvailability(titleKey: titleKey, region: region, offersJSON: data, fetchedAt: now))
        }
        try? modelContext.save()
    }

    public func availability(titleKey: String, region: String, maxAge: TimeInterval = 7 * 86_400, now: Date = Date()) -> [ProviderOffer]? {
        guard let row = try? modelContext.fetch(FetchDescriptor<WatchAvailability>(predicate: #Predicate { $0.titleKey == titleKey && $0.region == region })).first,
              now.timeIntervalSince(row.fetchedAt) <= maxAge else { return nil }
        return try? JSONDecoder().decode([ProviderOffer].self, from: row.offersJSON)
    }
}
