import Foundation

public struct SourceConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: SourceKind
    public var name: String
    public var isEnabled: Bool
    public var order: Int
    /// Jellyfin only (non-secret).
    public var serverURL: String?
    public var remoteURL: String?
    public var userID: String?
    public init(id: UUID = UUID(), kind: SourceKind, name: String, isEnabled: Bool = true, order: Int = 0,
                serverURL: String? = nil, remoteURL: String? = nil, userID: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isEnabled = isEnabled
        self.order = order
        self.serverURL = serverURL
        self.remoteURL = remoteURL
        self.userID = userID
    }
}

public struct SubscribedService: Codable, Sendable, Hashable, Identifiable {
    public var providerID: Int
    public var name: String
    public var id: Int { providerID }
    public init(providerID: Int, name: String) {
        self.providerID = providerID
        self.name = name
    }
}

public enum ShelfQuery: Codable, Sendable, Hashable {
    case preset(String)
    case traktList(String)
    case tmdbList(Int)
    case jellyfinCollection(String)
    case aiostreamsCatalog(String)
}

public struct ShelfConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var query: ShelfQuery
    public var isHidden: Bool
    public init(id: UUID = UUID(), title: String, query: ShelfQuery, isHidden: Bool = false) {
        self.id = id
        self.title = title
        self.query = query
        self.isHidden = isHidden
    }
}

public struct StreamPrefs: Codable, Sendable, Hashable {
    public enum Sort: String, Codable, Sendable, CaseIterable { case quality, size, cachedFirst }
    public var sourceOrder: [SourceKind] = [.jellyfin, .torbox, .aiostreams]
    public var minResolution: Resolution?
    public var requireDolbyVision = false
    public var requireAtmos = false
    public var maxSizeGB: Int?
    public var sort: Sort = .quality
    public var autoSelect = true
    public var preferLibrary = true
    public init() {}
}

public struct PlayerPrefs: Codable, Sendable, Hashable {
    public enum SkipIntro: String, Codable, Sendable { case off, button, auto }
    public var audioLanguages = ["eng"]
    public var subtitleLanguages = ["eng"]
    public var subtitlesEnabled = false
    public var showForcedSubtitles = true
    public var nextEpisodeLeadSeconds = 30
    public var skipIntro: SkipIntro = .button
    public var audioTranscode = "alac"
    public init() {}
}

/// Non-secret, durable settings. One versioned value in UserDefaults (budget 64 KB).
public struct DeviceConfig: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    public static let maxShelves = 20

    public var version = DeviceConfig.currentVersion
    public var sources: [SourceConfig] = []
    public var subscribedServices: [SubscribedService] = []
    public var watchRegion = "US"
    public var shelves: [ShelfConfig] = []
    public var streamPrefs = StreamPrefs()
    public var playerPrefs = PlayerPrefs()

    public init() {}

    public func validated() -> DeviceConfig {
        var copy = self
        copy.version = DeviceConfig.currentVersion
        copy.shelves = Array(shelves.prefix(DeviceConfig.maxShelves))
        return copy
    }
}

public struct DeviceConfigStore: @unchecked Sendable {
    static let key = "lanterna.deviceConfig"
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> DeviceConfig {
        guard let data = defaults.data(forKey: Self.key), let config = try? JSONDecoder().decode(DeviceConfig.self, from: data) else {
            return DeviceConfig()
        }
        return config
    }

    public func save(_ config: DeviceConfig) {
        if let data = try? JSONEncoder().encode(config.validated()) { defaults.set(data, forKey: Self.key) }
    }
}
