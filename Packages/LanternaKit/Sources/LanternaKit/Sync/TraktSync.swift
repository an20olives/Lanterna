import Foundation

/// Moves queued writes to Trakt and pulls playback, watchlist and history back. A local row that is still
/// waiting to be pushed is never overwritten by a remote one.
public struct TraktSync: @unchecked Sendable {
    public static let lastActivitiesKey = "lanterna.trakt.lastActivities"

    let client: TraktClient
    let progress: ProgressStore
    let outbox: OutboxStore
    let library: LibraryEntryStore
    let defaults: UserDefaults
    let runtimeMinutes: @Sendable (TitleRef) async -> Int?

    public init(client: TraktClient, progress: ProgressStore, outbox: OutboxStore, library: LibraryEntryStore, defaults: UserDefaults = .standard,
                runtimeMinutes: @escaping @Sendable (TitleRef) async -> Int?) {
        self.client = client
        self.progress = progress
        self.outbox = outbox
        self.library = library
        self.defaults = defaults
        self.runtimeMinutes = runtimeMinutes
    }

    /// Sends everything that is due. Stops early (without failing the items) when Trakt wants a new login.
    public func flush(now: Date = Date()) async {
        for entry in await outbox.due(now: now) where entry.target == .trakt {
            do {
                try await send(entry, now: now)
                await outbox.complete(idempotencyKey: entry.idempotencyKey)
                if entry.op == "scrobble", let payload = try? JSONDecoder().decode(ScrobblePayload.self, from: entry.payload), payload.action != "start" {
                    await progress.markSynced(titleKey: payload.titleKey)
                }
            } catch SourceError.needsCredentials {
                return
            } catch {
                await outbox.fail(idempotencyKey: entry.idempotencyKey, summary: "sync failed", now: now)
            }
        }
    }

    private func send(_ entry: OutboxEntry, now: Date) async throws {
        switch entry.op {
        case "scrobble":
            let payload = try JSONDecoder().decode(ScrobblePayload.self, from: entry.payload)
            // A start or pause that sat in the queue for minutes no longer describes what is on screen.
            if payload.action != "stop", now.timeIntervalSince(entry.createdAt) > 300 { return }
            guard let ref = TitleRef(key: payload.titleKey, imdbID: payload.imdbID), ref.tmdbID > 0,
                  let action = TraktScrobbleAction(rawValue: payload.action) else { return }
            try await client.scrobble(action, title: ref, progress: payload.progress)
        case "watchlistAdd", "watchlistRemove", "historyAdd", "historyRemove":
            let payload = try JSONDecoder().decode(ListOpPayload.self, from: entry.payload)
            guard let ref = TitleRef(key: payload.titleKey, imdbID: payload.imdbID), ref.tmdbID > 0 else { return }
            switch entry.op {
            case "watchlistAdd": try await client.addToWatchlist(ref)
            case "watchlistRemove": try await client.removeFromWatchlist(ref)
            case "historyAdd": try await client.addToHistory(ref, watchedAt: payload.watchedAt ?? now)
            default: try await client.removeFromHistory(ref)
            }
        default:
            return
        }
    }

    /// Returns true when something was pulled (Trakt reported new activity).
    @discardableResult
    public func pull() async -> Bool {
        guard let activities = try? await client.lastActivities() else { return false }
        let stamp = [activities.all, activities.movies?.values.sorted().last, activities.episodes?.values.sorted().last].compactMap { $0 }.joined(separator: "|")
        if defaults.string(forKey: Self.lastActivitiesKey) == stamp, !stamp.isEmpty { return false }

        if let playback = try? await client.playback() {
            for item in playback {
                await progress.applyRemote(titleKey: item.ref.key, showTMDBID: item.ref.kind == .episode ? item.ref.tmdbID : nil,
                                           fraction: item.progress / 100, duration: await duration(for: item.ref), at: item.pausedAt)
            }
        }
        if let watchlist = try? await client.watchlist() {
            await library.replace(.watchlist, with: watchlist.map(\.ref.key))
        }
        if let history = try? await client.history(limit: 100) {
            for item in history {
                await progress.applyRemote(titleKey: item.ref.key, showTMDBID: item.ref.kind == .episode ? item.ref.tmdbID : nil,
                                           fraction: 1, duration: await duration(for: item.ref), at: item.watchedAt)
            }
        }
        defaults.set(stamp, forKey: Self.lastActivitiesKey)
        return true
    }

    private func duration(for ref: TitleRef) async -> Double {
        if let existing = await progress.progress(for: ref.key), existing.durationSeconds > 0 { return existing.durationSeconds }
        return Double(await runtimeMinutes(ref) ?? 60) * 60
    }
}
