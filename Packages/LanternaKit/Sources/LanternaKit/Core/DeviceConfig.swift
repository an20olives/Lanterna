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

/// Filter-built shelf. Maps to TMDB discover parameters.
public struct DiscoverFilters: Codable, Sendable, Hashable {
    public var kind: TitleRef.Kind
    public var genre: Int?
    public var yearFrom: Int?
    public var yearTo: Int?
    public var minRating: Double?
    public var language: String?
    public var sort: String

    public init(kind: TitleRef.Kind, genre: Int? = nil, yearFrom: Int? = nil, yearTo: Int? = nil, minRating: Double? = nil,
                language: String? = nil, sort: String = "popularity.desc") {
        self.kind = kind
        self.genre = genre
        self.yearFrom = yearFrom
        self.yearTo = yearTo
        self.minRating = minRating
        self.language = language
        self.sort = sort
    }

    public var parameters: [String: String] {
        var params = ["sort_by": sort]
        let dateKey = kind == .movie ? "primary_release_date" : "first_air_date"
        if let genre { params["with_genres"] = String(genre) }
        if let yearFrom { params["\(dateKey).gte"] = "\(yearFrom)-01-01" }
        if let yearTo { params["\(dateKey).lte"] = "\(yearTo)-12-31" }
        if let minRating {
            params["vote_average.gte"] = String(minRating)
            params["vote_count.gte"] = "200"   // a rating filter without a vote floor returns obscure one-vote titles
        }
        if let language { params["with_original_language"] = language }
        return params
    }
}

public enum ShelfQuery: Codable, Sendable, Hashable {
    case discover(DiscoverFilters)
    case preset(String)
    case traktList(String)
    case tmdbList(Int)
    case jellyfinCollection(String)
    case aiostreamsCatalog(String)
    case mdblist(String)
    case letterboxd(String)
    case customList(UUID)
}

/// A list the user builds by hand. Holds title keys (`movie:603`) in the order they were added.
public struct CustomList: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var titleKeys: [String]
    public init(id: UUID = UUID(), name: String, titleKeys: [String] = []) {
        self.id = id
        self.name = name
        self.titleKeys = titleKeys
    }
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
    public enum SubtitleColor: String, Codable, Sendable { case white, yellow }
    /// 100 is the player's default size.
    public var subtitleSizePercent = 100
    public var subtitleColor: SubtitleColor = .white
    public var subtitleBackground = false
    /// Honoured by Engine C only; HLS text tracks cannot be shifted.
    public var subtitleDelaySeconds = 0.0
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlayerPrefs()
        audioLanguages = try c.decodeIfPresent([String].self, forKey: .audioLanguages) ?? d.audioLanguages
        subtitleLanguages = try c.decodeIfPresent([String].self, forKey: .subtitleLanguages) ?? d.subtitleLanguages
        subtitlesEnabled = try c.decodeIfPresent(Bool.self, forKey: .subtitlesEnabled) ?? d.subtitlesEnabled
        showForcedSubtitles = try c.decodeIfPresent(Bool.self, forKey: .showForcedSubtitles) ?? d.showForcedSubtitles
        nextEpisodeLeadSeconds = try c.decodeIfPresent(Int.self, forKey: .nextEpisodeLeadSeconds) ?? d.nextEpisodeLeadSeconds
        skipIntro = try c.decodeIfPresent(SkipIntro.self, forKey: .skipIntro) ?? d.skipIntro
        audioTranscode = try c.decodeIfPresent(String.self, forKey: .audioTranscode) ?? d.audioTranscode
        subtitleSizePercent = try c.decodeIfPresent(Int.self, forKey: .subtitleSizePercent) ?? d.subtitleSizePercent
        subtitleColor = try c.decodeIfPresent(SubtitleColor.self, forKey: .subtitleColor) ?? d.subtitleColor
        subtitleBackground = try c.decodeIfPresent(Bool.self, forKey: .subtitleBackground) ?? d.subtitleBackground
        subtitleDelaySeconds = try c.decodeIfPresent(Double.self, forKey: .subtitleDelaySeconds) ?? d.subtitleDelaySeconds
    }
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
    public var heroEnabled = true
    public var customLists: [CustomList] = []
    /// Local notifications for new episodes and releases of watchlist and favourite titles. iPhone and Mac only.
    public var notifyReleases = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        sources = try c.decodeIfPresent([SourceConfig].self, forKey: .sources) ?? []
        subscribedServices = try c.decodeIfPresent([SubscribedService].self, forKey: .subscribedServices) ?? []
        watchRegion = try c.decodeIfPresent(String.self, forKey: .watchRegion) ?? "US"
        shelves = try c.decodeIfPresent([ShelfConfig].self, forKey: .shelves) ?? []
        streamPrefs = try c.decodeIfPresent(StreamPrefs.self, forKey: .streamPrefs) ?? StreamPrefs()
        playerPrefs = try c.decodeIfPresent(PlayerPrefs.self, forKey: .playerPrefs) ?? PlayerPrefs()
        heroEnabled = try c.decodeIfPresent(Bool.self, forKey: .heroEnabled) ?? true
        customLists = try c.decodeIfPresent([CustomList].self, forKey: .customLists) ?? []
        notifyReleases = try c.decodeIfPresent(Bool.self, forKey: .notifyReleases) ?? false
    }

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
