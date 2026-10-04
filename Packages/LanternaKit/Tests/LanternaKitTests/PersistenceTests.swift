import Foundation
import SwiftData
import Testing
@testable import LanternaKit

struct PersistenceTests {
    func container() throws -> ModelContainer { try LanternaStore.makeContainer(inMemory: true) }

    @Test func schemaHoldsNoURLsOrSecrets() throws {
        let schema = Schema(SchemaV1.models, version: SchemaV1.versionIdentifier)
        #expect(schema.entities.count == 12)
        // "titleKey" and friends are identifiers; only credential-shaped names are banned.
        let banned = ["token", "secret", "password", "apikey"]
        for entity in schema.entities {
            for attribute in entity.attributes {
                #expect(String(describing: attribute.valueType) != "URL", "\(entity.name).\(attribute.name) is a URL")
                let name = attribute.name.lowercased()
                // idempotencyKey is a de-duplication label, not a secret.
                if name == "idempotencykey" { continue }
                #expect(name != "key" && !banned.contains { name.contains($0) }, "\(entity.name).\(attribute.name) looks like a secret")
            }
        }
    }

    @Test func progressCompletesAtNinetyPercentAndOrdersByRecency() async throws {
        let store = ProgressStore(modelContainer: try container())
        let t0 = Date(timeIntervalSince1970: 1_000)
        await store.record(titleKey: "movie:1", showTMDBID: nil, position: 600, duration: 6000, streamID: "s1", deviceName: "TV", now: t0)
        await store.record(titleKey: "episode:5:1:2", showTMDBID: 5, position: 100, duration: 2400, streamID: nil, deviceName: "TV", now: t0 + 60)
        await store.record(titleKey: "movie:2", showTMDBID: nil, position: 5800, duration: 6000, streamID: nil, deviceName: "TV", now: t0 + 120)
        let resume = await store.continueWatching(limit: 10, now: t0 + 200)
        #expect(resume.map(\.titleKey) == ["episode:5:1:2", "movie:1"])
        #expect(resume[0].fraction < 0.1)
        let done = await store.progress(for: "movie:2")
        #expect(done?.isCompleted == true)
    }

    @Test func hiddenItemsStayOutOfContinueWatchingUntilExpiry() async throws {
        let container = try container()
        let store = ProgressStore(modelContainer: container)
        let t0 = Date(timeIntervalSince1970: 1_000)
        await store.record(titleKey: "movie:1", showTMDBID: nil, position: 600, duration: 6000, streamID: nil, deviceName: "TV", now: t0)
        await store.hide(titleKey: "movie:1", until: t0 + 3600)
        #expect(await store.continueWatching(limit: 10, now: t0 + 10).isEmpty)
        #expect(await store.continueWatching(limit: 10, now: t0 + 7200).count == 1)
    }

    @Test func remoteProgressWinsOnlyWhenNewerAndNotPending() async throws {
        let store = ProgressStore(modelContainer: try container())
        let t0 = Date(timeIntervalSince1970: 1_000)
        await store.record(titleKey: "movie:1", showTMDBID: nil, position: 100, duration: 1000, streamID: nil, deviceName: "TV", now: t0)
        // Local row is pending: remote must not overwrite it.
        await store.applyRemote(titleKey: "movie:1", showTMDBID: nil, fraction: 0.9, duration: 1000, at: t0 + 50)
        #expect(await store.progress(for: "movie:1")?.positionSeconds == 100)
        await store.markSynced(titleKey: "movie:1")
        // Older remote loses, newer remote wins.
        await store.applyRemote(titleKey: "movie:1", showTMDBID: nil, fraction: 0.2, duration: 1000, at: t0 - 50)
        #expect(await store.progress(for: "movie:1")?.positionSeconds == 100)
        await store.applyRemote(titleKey: "movie:1", showTMDBID: nil, fraction: 0.5, duration: 1000, at: t0 + 500)
        #expect(await store.progress(for: "movie:1")?.positionSeconds == 500)
    }

    @Test func outboxDedupesRetriesWithBackoff() async throws {
        let store = OutboxStore(modelContainer: try container())
        let t0 = Date(timeIntervalSince1970: 1_000)
        await store.enqueue(idempotencyKey: "stop:1", target: .trakt, op: "scrobbleStop", payload: Data("{}".utf8), now: t0)
        await store.enqueue(idempotencyKey: "stop:1", target: .trakt, op: "scrobbleStop", payload: Data("{}".utf8), now: t0)
        #expect(await store.due(now: t0).count == 1)
        await store.fail(idempotencyKey: "stop:1", summary: "offline", now: t0)
        #expect(await store.due(now: t0 + 1).isEmpty)
        #expect(await store.due(now: t0 + 600).count == 1)
        await store.complete(idempotencyKey: "stop:1")
        #expect(await store.due(now: t0 + 10_000).isEmpty)
    }

    @Test func libraryEntriesAreUniquePerKindAndTitle() async throws {
        let store = LibraryEntryStore(modelContainer: try container())
        await store.add(.watchlist, titleKey: "movie:1")
        await store.add(.watchlist, titleKey: "movie:1")
        await store.add(.favorite, titleKey: "movie:1")
        #expect(await store.titleKeys(.watchlist) == ["movie:1"])
        #expect(await store.contains(.favorite, titleKey: "movie:1"))
        await store.remove(.watchlist, titleKey: "movie:1")
        #expect(await store.titleKeys(.watchlist).isEmpty)
    }

    @Test func titleCacheRoundTripsDetail() async throws {
        let store = CacheStore(modelContainer: try container())
        let detail = TitleDetail(summary: TitleSummary(ref: .movie(tmdbID: 603, imdbID: "tt0133093"), title: "The Matrix", year: 1999), genres: ["Action"])
        let now = Date(timeIntervalSince1970: 5_000)
        await store.save(detail, now: now)
        #expect(await store.detail(for: "movie:603", maxAge: 3600, now: now + 10)?.genres == ["Action"])
        #expect(await store.detail(for: "movie:603", maxAge: 3600, now: now + 7200) == nil)
    }
}

struct MarkWatchedTests {
    @Test func markWatchedCompletesAndUnwatchedClears() async throws {
        let store = ProgressStore(modelContainer: try LanternaStore.makeContainer(inMemory: true))
        await store.markWatched(titleKey: "episode:5:1:1", showTMDBID: 5, duration: 2700)
        #expect(await store.progress(for: "episode:5:1:1")?.isCompleted == true)
        #expect(await store.history(limit: 5).map(\.titleKey) == ["episode:5:1:1"])
        await store.markUnwatched(titleKey: "episode:5:1:1")
        #expect(await store.progress(for: "episode:5:1:1") == nil)
    }
}
