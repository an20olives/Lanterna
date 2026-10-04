import Foundation
import LanternaKit
import Observation

extension AppEnvironment {
    func traktClient(authorized: Bool = true) -> TraktClient? {
        guard let id = secret(.traktClientID), let secretValue = secret(.traktClientSecret) else { return nil }
        return TraktClient(clientID: id, clientSecret: secretValue, accessToken: authorized ? secret(.traktAccessToken) : nil)
    }

    var traktExpiry: Date? {
        ((try? keychain.string(account: "trakt.expiresAt")) ?? nil).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }

    /// Both tokens are written together: Trakt rotates the refresh token on every refresh.
    func storeTrakt(_ tokens: TraktTokens) {
        try? keychain.set(tokens.refreshToken, for: .traktRefreshToken)
        try? keychain.set(tokens.accessToken, for: .traktAccessToken)
        try? keychain.set(String(tokens.expiresAt.timeIntervalSince1970), account: "trakt.expiresAt")
        revision += 1
    }

    func signOutTrakt() {
        for key in [KeychainKey.traktAccessToken, .traktRefreshToken] { try? keychain.remove(key) }
        try? keychain.remove(account: "trakt.expiresAt")
        UserDefaults.standard.removeObject(forKey: SyncEngine.lastActivitiesKey)
        revision += 1
    }

    /// A client with a fresh access token, refreshing first when it expires within a day.
    func authorizedTrakt() async -> TraktClient? {
        guard secret(.traktAccessToken) != nil, var client = traktClient() else { return nil }
        if let expiry = traktExpiry, expiry < Date().addingTimeInterval(86_400), let refresh = secret(.traktRefreshToken) {
            guard let tokens = try? await client.refresh(refreshToken: refresh) else { return client }
            storeTrakt(tokens)
            client = traktClient() ?? client
        }
        return client
    }
}

/// Moves queued writes to Trakt and pulls playback, watchlist and history back. Local progress is never
/// overwritten while it is still waiting to be pushed.
@MainActor
final class SyncEngine {
    static let lastActivitiesKey = "lanterna.trakt.lastActivities"
    private weak var env: AppEnvironment?
    private var running = false
    private var again = false
    private var timer: Task<Void, Never>?

    init(env: AppEnvironment) {
        self.env = env
        env.syncKick = { [weak self] in self?.kick() }
    }

    func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                self?.kick()
            }
        }
    }

    func kick() {
        if running { again = true; return }
        running = true
        Task {
            repeat {
                again = false
                await run()
            } while again
            running = false
        }
    }

    private func run() async {
        guard let env, let client = await env.authorizedTrakt() else { return }
        await flush(env: env, client: client)
        await pull(env: env, client: client)
        env.lastSync = Date()
    }

    func flush(env: AppEnvironment, client: TraktClient, now: Date = Date()) async {
        for entry in await env.outbox.due(now: now) where entry.target == .trakt {
            do {
                try await send(entry, client: client, now: now)
                await env.outbox.complete(idempotencyKey: entry.idempotencyKey)
                if entry.op == "scrobble", let payload = try? JSONDecoder().decode(ScrobblePayload.self, from: entry.payload), payload.action != "start" {
                    await env.progress.markSynced(titleKey: payload.titleKey)
                }
            } catch SourceError.needsCredentials {
                return
            } catch {
                await env.outbox.fail(idempotencyKey: entry.idempotencyKey, summary: "sync failed", now: now)
            }
        }
    }

    private func send(_ entry: OutboxEntry, client: TraktClient, now: Date) async throws {
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

    func pull(env: AppEnvironment, client: TraktClient) async {
        // Local pending rows were just pushed by flush; anything still pending keeps winning over remote.
        guard let activities = try? await client.lastActivities() else { return }
        let stamp = [activities.all, activities.movies?.values.sorted().last, activities.episodes?.values.sorted().last].compactMap { $0 }.joined(separator: "|")
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.lastActivitiesKey) == stamp, !stamp.isEmpty { return }

        if let playback = try? await client.playback() {
            for item in playback {
                let duration = await duration(for: item.ref, env: env)
                await env.progress.applyRemote(titleKey: item.ref.key, showTMDBID: item.ref.kind == .episode ? item.ref.tmdbID : nil,
                                               fraction: item.progress / 100, duration: duration, at: item.pausedAt)
            }
        }
        if let watchlist = try? await client.watchlist() {
            await env.library.replace(.watchlist, with: watchlist.map(\.ref.key))
        }
        if let history = try? await client.history(limit: 100) {
            for item in history {
                let duration = await duration(for: item.ref, env: env)
                await env.progress.applyRemote(titleKey: item.ref.key, showTMDBID: item.ref.kind == .episode ? item.ref.tmdbID : nil,
                                               fraction: 1, duration: duration, at: item.watchedAt)
            }
        }
        defaults.set(stamp, forKey: Self.lastActivitiesKey)
        env.revision += 1
    }

    private func duration(for ref: TitleRef, env: AppEnvironment) async -> Double {
        if let existing = await env.progress.progress(for: ref.key), existing.durationSeconds > 0 { return existing.durationSeconds }
        let minutes = await env.detail(for: ref)?.runtimeMinutes ?? 60
        return Double(minutes) * 60
    }

    /// Cold launch and foreground: push first, then show remote progress.
    func syncNow() async {
        if running { return }
        running = true
        await run()
        running = false
    }
}
