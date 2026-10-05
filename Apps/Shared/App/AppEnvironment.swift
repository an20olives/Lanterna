import Foundation
import LanternaKit
import Observation
import SwiftData
import SwiftUI

/// One place that owns config, stores, sources and API clients. Views read it; nothing else is global.
@MainActor
@Observable
final class AppEnvironment {
    let keychain = KeychainStore()
    let configStore = DeviceConfigStore()
    var config: DeviceConfig
    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let progress: ProgressStore
    @ObservationIgnored let outbox: OutboxStore
    @ObservationIgnored let library: LibraryEntryStore
    @ObservationIgnored let cache: CacheStore
    @ObservationIgnored private(set) var registry = SourceRegistry(sources: [])

    private(set) var tmdb: TMDBClient?
    private(set) var hasAIOStreams = false
    private(set) var hasTorBox = false
    private(set) var hasDevMedia = false
    /// Bumps whenever sources or credentials change so views reload.
    var revision = 0
    let itunes = ITunesPreviewClient()
    var lastSync: Date?
    var deviceName: String = "Apple TV"
    /// tvOS sets this to show the P0 player lab from Settings.
    /// Set by the sync engine; called after anything is queued for Trakt.
    @ObservationIgnored var syncKick: (@MainActor () -> Void)?
    @ObservationIgnored var labView: (@MainActor () -> AnyView)?

    var isDemo: Bool { tmdb == nil }

    init() {
        config = configStore.load()
        let freshStore = ProcessInfo.processInfo.arguments.contains("-uitest-reset")
        let container = (freshStore ? nil : try? LanternaStore.makeContainer()) ?? (try! LanternaStore.makeContainer(inMemory: true))
        self.container = container
        progress = ProgressStore(modelContainer: container)
        outbox = OutboxStore(modelContainer: container)
        library = LibraryEntryStore(modelContainer: container)
        cache = CacheStore(modelContainer: container)
        #if os(tvOS)
        deviceName = "Apple TV"
        #else
        deviceName = "iPhone"
        #endif
        seedDevCredentials()
        rebuild()
    }

    /// Dev builds made with Config/Local.xcconfig carry credentials so the first launch skips setup.
    private func seedDevCredentials() {
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            for key in [KeychainKey.aiostreamsManifestURL, .tmdbReadToken, .torboxAPIKey, .traktClientID, .traktClientSecret, .traktAccessToken, .traktRefreshToken] {
                try? keychain.remove(key)
            }
            // Reset runs start without the featured strip so remote navigation is fixed; `-uitest-hero` turns it back on.
            var fresh = DeviceConfig()
            fresh.heroEnabled = ProcessInfo.processInfo.arguments.contains("-uitest-hero")
            configStore.save(fresh)
            config = fresh
            return
        }
        // Lets a UI test turn the featured strip back on without wiping the Keychain.
        if ProcessInfo.processInfo.arguments.contains("-uitest-hero") { config.heroEnabled = true }
        func seed(_ plistKey: String, _ key: KeychainKey, prefix: String = "") {
            guard (try? keychain.string(for: key)) ?? nil == nil,
                  let value = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String, !value.isEmpty, !value.hasPrefix("$(") else { return }
            try? keychain.set(prefix + value, for: key)
        }
        seed("LanternaDevManifest", .aiostreamsManifestURL, prefix: "https://")
        seed("LanternaDevTMDB", .tmdbReadToken)
        seed("LanternaDevTorBox", .torboxAPIKey)
        seed("LanternaDevTraktID", .traktClientID)
        seed("LanternaDevTraktSecret", .traktClientSecret)
    }

    func secret(_ key: KeychainKey) -> String? {
        guard let value = (try? keychain.string(for: key)) ?? nil, !value.isEmpty else { return nil }
        return value
    }

    func setSecret(_ value: String?, for key: KeychainKey) {
        if let value, !value.isEmpty { try? keychain.set(value, for: key) } else { try? keychain.remove(key) }
        rebuild()
    }

    func updateConfig(_ change: (inout DeviceConfig) -> Void) {
        change(&config)
        config = config.validated()
        configStore.save(config)
        revision += 1
    }

    /// Rebuilds sources from config and Keychain. A missing secret is a normal state, never an error.
    func rebuild() {
        var sources: [any MediaSource] = []
        if let token = secret(.tmdbReadToken) {
            let client = TMDBClient(readToken: token)
            tmdb = client
            sources.append(TMDBSource(id: Self.sourceID(.tmdb), client: client, region: config.watchRegion))
        } else {
            tmdb = nil
        }
        if let text = secret(.aiostreamsManifestURL), let url = URL(string: text), let client = AIOStreamsClient(manifestURL: url) {
            sources.append(AIOStreamsSource(id: Self.sourceID(.aiostreams), client: client))
            hasAIOStreams = true
        } else {
            hasAIOStreams = false
        }
        if let key = secret(.torboxAPIKey) {
            sources.append(TorBoxSource(id: Self.sourceID(.torbox), client: TorBoxClient(apiKey: key)))
            hasTorBox = true
        } else {
            hasTorBox = false
        }
        if let dev = DevMediaSource.fromLaunchArguments(id: Self.sourceID(.torbox)) {
            sources.append(dev)
            hasDevMedia = true
        }
        for config in config.sources where config.kind == .jellyfin && config.isEnabled {
            guard let server = config.serverURL.flatMap(URL.init(string:)),
                  let token = (try? keychain.string(account: "jellyfin.\(config.id.uuidString).token")) ?? nil else { continue }
            let device = JellyfinDevice(deviceID: jellyfinDeviceID(), deviceName: deviceName, version: "0.1")
            sources.append(JellyfinSource(id: SourceID(config.id), displayName: config.name,
                                          client: JellyfinClient(baseURLs: [server] + (config.remoteURL.flatMap(URL.init(string:)).map { [$0] } ?? []),
                                                                 device: device, token: token, userID: config.userID)))
        }
        let registry = registry
        Task { await registry.setSources(sources) }
        revision += 1
    }

    /// Stable IDs so candidates stay valid across a rebuild.
    static func sourceID(_ kind: SourceKind) -> SourceID {
        let index = SourceKind.allCases.firstIndex(of: kind) ?? 0
        return SourceID(UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!)
    }

    func jellyfinDeviceID() -> String {
        if let id = (try? keychain.string(account: "jellyfin.deviceID")) ?? nil { return id }
        let id = UUID().uuidString
        try? keychain.set(id, account: "jellyfin.deviceID")
        return id
    }

    var hasAnySource: Bool { tmdb != nil || hasAIOStreams || hasTorBox || hasDevMedia || config.sources.contains { $0.kind == .jellyfin } }
}
