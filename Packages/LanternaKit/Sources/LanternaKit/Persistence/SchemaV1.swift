import Foundation
import SwiftData

enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [SourceRecord.self, IndexedItem.self, TitleCache.self, EpisodeCache.self, PlaybackProgress.self, LibraryEntry.self,
         SyncOperation.self, StreamChoice.self, ProbeRecord.self, WatchAvailability.self, IntroMarker.self, PairedDevice.self]
    }
}

/// No secret ever enters SwiftData: no URL-typed or token-named fields (a test enforces this).
@Model final class SourceRecord {
    #Unique<SourceRecord>([\.sourceID])
    var sourceID: UUID
    var kindRaw: String
    var displayName: String
    var isEnabled: Bool
    var sortOrder: Int
    var jellyfinServerID: String?
    var jellyfinUserID: String?
    var selectedLibraryIDs: [String]
    var lastSyncAt: Date?
    var lastErrorSummary: String?
    @Relationship(deleteRule: .cascade, inverse: \IndexedItem.source) var items: [IndexedItem] = []
    var createdAt: Date
    var updatedAt: Date
    init(sourceID: UUID, kindRaw: String, displayName: String, isEnabled: Bool = true, sortOrder: Int = 0) {
        self.sourceID = sourceID; self.kindRaw = kindRaw; self.displayName = displayName; self.isEnabled = isEnabled
        self.sortOrder = sortOrder; self.selectedLibraryIDs = []; self.createdAt = Date(); self.updatedAt = Date()
    }
}

@Model final class IndexedItem {
    #Unique<IndexedItem>([\.sourceID, \.externalID])
    #Index<IndexedItem>([\.titleKey], [\.dateAdded])
    var sourceID: UUID
    var externalID: String
    var source: SourceRecord?
    var titleKey: String?
    var matchStateRaw: String
    var parsedTitle: String
    var parsedYear: Int?
    var season: Int?
    var episode: Int?
    var genres: [Int]
    var sizeBytes: Int64?
    var dateAdded: Date
    var statusRaw: String?
    var createdAt: Date
    var updatedAt: Date
    init(sourceID: UUID, externalID: String, parsedTitle: String, matchStateRaw: String = "unmatched", dateAdded: Date = Date()) {
        self.sourceID = sourceID; self.externalID = externalID; self.parsedTitle = parsedTitle; self.matchStateRaw = matchStateRaw
        self.genres = []; self.dateAdded = dateAdded; self.createdAt = Date(); self.updatedAt = Date()
    }
}

@Model final class TitleCache {
    #Unique<TitleCache>([\.titleKey])
    var titleKey: String
    var tmdbID: Int
    var kindRaw: String
    var imdbID: String?
    var title: String
    var year: Int?
    var detailJSON: Data?
    var fetchedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \EpisodeCache.show) var episodes: [EpisodeCache] = []
    var createdAt: Date
    var updatedAt: Date
    init(titleKey: String, tmdbID: Int, kindRaw: String, title: String, fetchedAt: Date) {
        self.titleKey = titleKey; self.tmdbID = tmdbID; self.kindRaw = kindRaw; self.title = title; self.fetchedAt = fetchedAt
        self.createdAt = Date(); self.updatedAt = Date()
    }
}

@Model final class EpisodeCache {
    #Unique<EpisodeCache>([\.titleKey])
    var titleKey: String
    var show: TitleCache?
    var season: Int
    var episode: Int
    var name: String?
    var airDate: Date?
    var runtimeMinutes: Int?
    var fetchedAt: Date
    var createdAt: Date
    var updatedAt: Date
    init(titleKey: String, season: Int, episode: Int, fetchedAt: Date) {
        self.titleKey = titleKey; self.season = season; self.episode = episode; self.fetchedAt = fetchedAt
        self.createdAt = Date(); self.updatedAt = Date()
    }
}

@Model final class PlaybackProgress {
    #Unique<PlaybackProgress>([\.titleKey])
    #Index<PlaybackProgress>([\.updatedAt])
    var titleKey: String
    var showTMDBID: Int?
    var positionSeconds: Double
    var durationSeconds: Double
    var isCompleted: Bool
    var traktPlaybackID: Int64?
    var syncStateRaw: String
    var lastStreamID: String?
    var deviceName: String
    var createdAt: Date
    var updatedAt: Date
    init(titleKey: String, positionSeconds: Double, durationSeconds: Double, deviceName: String, updatedAt: Date) {
        self.titleKey = titleKey; self.positionSeconds = positionSeconds; self.durationSeconds = durationSeconds
        self.isCompleted = false; self.syncStateRaw = "pending"; self.deviceName = deviceName
        self.createdAt = updatedAt; self.updatedAt = updatedAt
    }
}

@Model final class LibraryEntry {
    #Unique<LibraryEntry>([\.kindRaw, \.titleKey, \.playID])
    #Index<LibraryEntry>([\.kindRaw, \.updatedAt])
    var kindRaw: String
    var titleKey: String
    var playID: String
    var watchedAt: Date?
    var rating: Int?
    var hiddenUntil: Date?
    var traktID: Int64?
    var syncStateRaw: String
    var createdAt: Date
    var updatedAt: Date
    init(kindRaw: String, titleKey: String, playID: String = "") {
        self.kindRaw = kindRaw; self.titleKey = titleKey; self.playID = playID; self.syncStateRaw = "pending"
        self.createdAt = Date(); self.updatedAt = Date()
    }
}

/// Outbox for Trakt and Jellyfin writes. The only non-rebuildable table.
@Model final class SyncOperation {
    #Unique<SyncOperation>([\.idempotencyKey])
    #Index<SyncOperation>([\.nextAttemptAt])
    var idempotencyKey: String
    var targetRaw: String
    var opRaw: String
    var payload: Data
    var attempts: Int
    var nextAttemptAt: Date
    var lastErrorSummary: String?
    var createdAt: Date
    var updatedAt: Date
    init(idempotencyKey: String, targetRaw: String, opRaw: String, payload: Data, now: Date) {
        self.idempotencyKey = idempotencyKey; self.targetRaw = targetRaw; self.opRaw = opRaw; self.payload = payload
        self.attempts = 0; self.nextAttemptAt = now; self.createdAt = now; self.updatedAt = now
    }
}

@Model final class StreamChoice {
    #Unique<StreamChoice>([\.titleKey])
    var titleKey: String
    var streamID: String
    var sourceID: UUID
    var audioLanguage: String?
    var subtitleLanguage: String?
    var createdAt: Date
    var updatedAt: Date
    init(titleKey: String, streamID: String, sourceID: UUID) {
        self.titleKey = titleKey; self.streamID = streamID; self.sourceID = sourceID; self.createdAt = Date(); self.updatedAt = Date()
    }
}

@Model final class ProbeRecord {
    #Unique<ProbeRecord>([\.streamID, \.probedAt])
    #Index<ProbeRecord>([\.probedAt])
    var streamID: String
    var titleKey: String?
    var probeJSON: Data
    var engineRaw: String
    var reasons: [String]
    var outcomeRaw: String
    var failureSummary: String?
    var ttffMillis: Int?
    var probedAt: Date
    var createdAt: Date
    var updatedAt: Date
    init(streamID: String, probeJSON: Data, engineRaw: String, reasons: [String], outcomeRaw: String, probedAt: Date) {
        self.streamID = streamID; self.probeJSON = probeJSON; self.engineRaw = engineRaw; self.reasons = reasons
        self.outcomeRaw = outcomeRaw; self.probedAt = probedAt; self.createdAt = probedAt; self.updatedAt = probedAt
    }
}

@Model final class WatchAvailability {
    #Unique<WatchAvailability>([\.titleKey, \.region])
    var titleKey: String
    var region: String
    var offersJSON: Data
    var fetchedAt: Date
    var createdAt: Date
    var updatedAt: Date
    init(titleKey: String, region: String, offersJSON: Data, fetchedAt: Date) {
        self.titleKey = titleKey; self.region = region; self.offersJSON = offersJSON; self.fetchedAt = fetchedAt
        self.createdAt = fetchedAt; self.updatedAt = fetchedAt
    }
}

@Model final class IntroMarker {
    #Unique<IntroMarker>([\.titleKey, \.kindRaw, \.sourceRaw])
    var titleKey: String
    var kindRaw: String
    var startSeconds: Double
    var endSeconds: Double
    var sourceRaw: String
    var createdAt: Date
    var updatedAt: Date
    init(titleKey: String, kindRaw: String, startSeconds: Double, endSeconds: Double, sourceRaw: String) {
        self.titleKey = titleKey; self.kindRaw = kindRaw; self.startSeconds = startSeconds; self.endSeconds = endSeconds
        self.sourceRaw = sourceRaw; self.createdAt = Date(); self.updatedAt = Date()
    }
}

@Model final class PairedDevice {
    #Unique<PairedDevice>([\.deviceID])
    var deviceID: UUID
    var name: String
    var platformRaw: String
    var lastPairedAt: Date
    var createdAt: Date
    var updatedAt: Date
    init(deviceID: UUID, name: String, platformRaw: String, lastPairedAt: Date) {
        self.deviceID = deviceID; self.name = name; self.platformRaw = platformRaw; self.lastPairedAt = lastPairedAt
        self.createdAt = lastPairedAt; self.updatedAt = lastPairedAt
    }
}
