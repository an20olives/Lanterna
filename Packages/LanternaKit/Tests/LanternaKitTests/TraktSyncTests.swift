import Foundation
import Testing
@testable import LanternaKit

/// A tiny stateful Trakt: remembers the last scrobble per title and serves it back from /sync/playback.
final class FakeTrakt: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var scrobbles: [(action: String, tmdb: Int, progress: Double)] = []
    private var playback: [(id: Int, tmdb: Int, progress: Double, at: Date)] = []
    private var watchlist: [Int] = []
    private var nextID = 1
    var failNextScrobbles = 0
    var now: () -> Date = { Date() }

    func transport() -> ScriptedTransport {
        ScriptedTransport { [self] request in
            lock.lock(); defer { lock.unlock() }
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            switch path {
            case "/scrobble/start", "/scrobble/pause", "/scrobble/stop":
                if failNextScrobbles > 0 { failNextScrobbles -= 1; return .init(status: 503, body: "{}") }
                let action = String(path.split(separator: "/").last!)
                let tmdb = ((body["movie"] as? [String: Any])?["ids"] as? [String: Int])?["tmdb"]
                    ?? ((body["show"] as? [String: Any])?["ids"] as? [String: Int])?["tmdb"] ?? 0
                let progress = body["progress"] as? Double ?? 0
                scrobbles.append((action, tmdb, progress))
                if action != "start" {
                    playback.removeAll { $0.tmdb == tmdb }
                    if progress < 80 { playback.append((nextID, tmdb, progress, now())); nextID += 1 }
                }
                return .init(body: #"{"id":1}"#)
            case "/sync/last_activities":
                return .init(body: "{\"all\":\"\(playback.count)-\(scrobbles.count)-\(watchlist.count)\"}")
            case "/sync/playback":
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let items = playback.map { "{\"id\":\($0.id),\"progress\":\($0.progress),\"paused_at\":\"\(iso.string(from: $0.at))\",\"type\":\"movie\",\"movie\":{\"title\":\"M\",\"year\":2000,\"ids\":{\"tmdb\":\($0.tmdb)}}}" }
                return .init(body: "[" + items.joined(separator: ",") + "]")
            case "/sync/watchlist":
                let iso = ISO8601DateFormatter()
                let items = watchlist.map { "{\"listed_at\":\"\(iso.string(from: Date()))\",\"type\":\"movie\",\"movie\":{\"title\":\"M\",\"year\":2000,\"ids\":{\"tmdb\":\($0)}}}" }
                return .init(body: "[" + items.joined(separator: ",") + "]")
            case "/sync/history":
                return .init(body: "[]")
            default:
                return .init(status: 404, body: "{}")
            }
        }
    }
}

struct TraktSyncTests {
    struct Device {
        let progress: ProgressStore
        let outbox: OutboxStore
        let library: LibraryEntryStore
        let sync: TraktSync
        let defaults: UserDefaults
    }

    func device(_ name: String, fake: FakeTrakt) throws -> Device {
        let container = try LanternaStore.makeContainer(inMemory: true)
        let progress = ProgressStore(modelContainer: container)
        let outbox = OutboxStore(modelContainer: container)
        let library = LibraryEntryStore(modelContainer: container)
        let defaults = UserDefaults(suiteName: "lanterna.sync.\(UUID().uuidString)")!
        let transport = fake.transport()
        let client = TraktClient(clientID: "CID", clientSecret: "SEC", accessToken: "ACC",
                                 http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in }), transport: transport)
        let sync = TraktSync(client: client, progress: progress, outbox: outbox, library: library, defaults: defaults,
                             runtimeMinutes: { _ in 100 })
        return Device(progress: progress, outbox: outbox, library: library, sync: sync, defaults: defaults)
    }

    private func stopOnPhone(_ phone: Device, at seconds: Double, now: Date) async throws {
        await phone.progress.record(titleKey: "movie:603", showTMDBID: nil, position: seconds, duration: 6000, streamID: nil, deviceName: "iPhone", now: now)
        let payload = ScrobblePayload(titleKey: "movie:603", imdbID: nil, action: "stop", progress: seconds / 6000 * 100)
        await phone.outbox.enqueue(idempotencyKey: "scrobble-stop:movie:603:S1:0", target: .trakt, op: "scrobble",
                                   payload: try JSONEncoder().encode(payload), now: now)
    }

    @Test func startOnPhoneResumeOnTVWithinTenSeconds() async throws {
        let fake = FakeTrakt()
        let phone = try device("phone", fake: fake)
        let tv = try device("tv", fake: fake)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        fake.now = { t0 }

        // iPhone stops at 41:10 of a 100 minute movie.
        try await stopOnPhone(phone, at: 2470, now: t0)
        await phone.sync.flush(now: t0)
        #expect(fake.scrobbles.last?.action == "stop")
        #expect(await phone.outbox.count() == 0)
        #expect(await phone.progress.progress(for: "movie:603")?.syncState == "synced")

        // Five seconds later the Apple TV opens Home: pull first, then show Continue Watching.
        #expect(await tv.sync.pull() == true)
        let resume = await tv.progress.continueWatching(limit: 5, now: t0 + 5)
        let item = try #require(resume.first)
        #expect(item.titleKey == "movie:603")
        #expect(abs(item.positionSeconds - 2470) < 10, "resume point should be within 10 s, got \(item.positionSeconds)")
    }

    @Test func pendingLocalProgressBeatsAnOlderRemoteOne() async throws {
        let fake = FakeTrakt()
        let tv = try device("tv", fake: fake)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        fake.now = { t0 - 100 }
        // Remote says 10%, but the TV has newer unsent progress at 50%.
        let other = try device("other", fake: fake)
        try await stopOnPhone(other, at: 600, now: t0 - 100)
        await other.sync.flush(now: t0 - 100)
        await tv.progress.record(titleKey: "movie:603", showTMDBID: nil, position: 3000, duration: 6000, streamID: nil, deviceName: "TV", now: t0)
        _ = await tv.sync.pull()
        #expect(await tv.progress.progress(for: "movie:603")?.positionSeconds == 3000)
    }

    @Test func failedScrobbleIsRetriedWithBackoffAndNeverDoubled() async throws {
        let fake = FakeTrakt()
        fake.failNextScrobbles = 1
        let phone = try device("phone", fake: fake)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try await stopOnPhone(phone, at: 1000, now: t0)
        await phone.sync.flush(now: t0)
        #expect(await phone.outbox.count() == 1, "kept for retry")
        #expect(fake.scrobbles.isEmpty)
        await phone.sync.flush(now: t0 + 1)      // still backing off
        #expect(fake.scrobbles.isEmpty)
        await phone.sync.flush(now: t0 + 60)     // retry succeeds
        #expect(fake.scrobbles.count == 1)
        #expect(await phone.outbox.count() == 0)
        await phone.sync.flush(now: t0 + 120)
        #expect(fake.scrobbles.count == 1, "no second stop")
    }

    @Test func staleStartAndPauseAreDroppedNotSent() async throws {
        let fake = FakeTrakt()
        let phone = try device("phone", fake: fake)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = ScrobblePayload(titleKey: "movie:603", imdbID: nil, action: "start", progress: 1)
        await phone.outbox.enqueue(idempotencyKey: "scrobble-start:movie:603:S:1", target: .trakt, op: "scrobble", payload: try JSONEncoder().encode(payload), now: t0)
        await phone.sync.flush(now: t0 + 3600)
        #expect(fake.scrobbles.isEmpty)
        #expect(await phone.outbox.count() == 0)
    }

    @Test func pullSkipsWorkWhenNothingChanged() async throws {
        let fake = FakeTrakt()
        let tv = try device("tv", fake: fake)
        #expect(await tv.sync.pull() == true)
        #expect(await tv.sync.pull() == false)
    }
}
