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

/// Schedules `TraktSync` runs: on launch, foreground, after anything is queued, and every five minutes.
@MainActor
final class SyncEngine {
    static let lastActivitiesKey = TraktSync.lastActivitiesKey
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

    /// Cold launch and foreground: push first, then show remote progress.
    func syncNow() async {
        if running { return }
        running = true
        await run()
        running = false
    }

    private func run() async {
        guard let env, let client = await env.authorizedTrakt() else { return }
        let sync = TraktSync(client: client, progress: env.progress, outbox: env.outbox, library: env.library,
                             runtimeMinutes: { [weak env] ref in await env?.detail(for: ref)?.runtimeMinutes })
        await sync.flush()
        if await sync.pull() { env.revision += 1 }
        env.lastSync = Date()
    }
}
