import Foundation

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case aiostreams, torbox, jellyfin, tmdb, trakt
}

public struct SourceID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct SourceCapabilities: OptionSet, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let catalogs = SourceCapabilities(rawValue: 1 << 0)
    public static let metadata = SourceCapabilities(rawValue: 1 << 1)
    public static let streams = SourceCapabilities(rawValue: 1 << 2)
    public static let subtitles = SourceCapabilities(rawValue: 1 << 3)
    public static let library = SourceCapabilities(rawValue: 1 << 4)
    public static let watchProviders = SourceCapabilities(rawValue: 1 << 5)
    public static let progressSync = SourceCapabilities(rawValue: 1 << 6)
    public static let userLists = SourceCapabilities(rawValue: 1 << 7)
}

public enum SourceHealth: Sendable, Equatable {
    case ok
    case needsCredentials
    case unreachable(String)
    case rateLimited(until: Date?)
}

public enum SourceError: Error, Equatable {
    case unsupported
    case needsCredentials
    case unreachable(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case malformedResponse
    case notFound
}

public struct PageCursor: Hashable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

public struct Page<Item: Sendable>: Sendable {
    public var items: [Item]
    public var next: PageCursor?
    public init(items: [Item], next: PageCursor? = nil) {
        self.items = items
        self.next = next
    }
}

public struct CatalogDescriptor: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: TitleRef.Kind
    public init(id: String, title: String, kind: TitleRef.Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

/// A poster-sized title for rows and grids.
public struct TitleSummary: Identifiable, Hashable, Codable, Sendable {
    public var ref: TitleRef
    public var title: String
    public var year: Int?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var rating: Double?
    public var id: String { ref.key }

    public init(ref: TitleRef, title: String, year: Int? = nil, overview: String? = nil, posterPath: String? = nil,
                backdropPath: String? = nil, rating: Double? = nil) {
        self.ref = ref
        self.title = title
        self.year = year
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.rating = rating
    }
}

public struct CastMember: Hashable, Codable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var character: String?
    public var profilePath: String?
    public init(id: Int, name: String, character: String? = nil, profilePath: String? = nil) {
        self.id = id
        self.name = name
        self.character = character
        self.profilePath = profilePath
    }
}

public struct Trailer: Hashable, Codable, Sendable, Identifiable {
    public var id: String { youtubeKey }
    public var youtubeKey: String
    public var name: String
    public init(youtubeKey: String, name: String) {
        self.youtubeKey = youtubeKey
        self.name = name
    }
}

public struct SeasonSummary: Hashable, Codable, Sendable, Identifiable {
    public var number: Int
    public var name: String
    public var episodeCount: Int
    public var posterPath: String?
    public var id: Int { number }
    public init(number: Int, name: String, episodeCount: Int, posterPath: String? = nil) {
        self.number = number
        self.name = name
        self.episodeCount = episodeCount
        self.posterPath = posterPath
    }
}

public struct EpisodeSummary: Hashable, Codable, Sendable, Identifiable {
    public var season: Int
    public var number: Int
    public var name: String
    public var overview: String?
    public var airDate: Date?
    public var stillPath: String?
    public var runtimeMinutes: Int?
    public var rating: Double?
    public var id: String { "\(season)x\(number)" }
    public init(season: Int, number: Int, name: String, overview: String? = nil, airDate: Date? = nil,
                stillPath: String? = nil, runtimeMinutes: Int? = nil, rating: Double? = nil) {
        self.season = season
        self.number = number
        self.name = name
        self.overview = overview
        self.airDate = airDate
        self.stillPath = stillPath
        self.runtimeMinutes = runtimeMinutes
        self.rating = rating
    }
}

public struct UpcomingRelease: Hashable, Codable, Sendable {
    public var date: Date
    /// "S2 E5" for an episode, "Release" for a movie.
    public var label: String
    public init(date: Date, label: String) {
        self.date = date
        self.label = label
    }
}

public struct TitleDetail: Hashable, Codable, Sendable {
    public var summary: TitleSummary
    public var tagline: String?
    public var runtimeMinutes: Int?
    public var certification: String?
    public var genres: [String]
    public var logoPath: String?
    public var cast: [CastMember]
    public var trailers: [Trailer]
    public var seasons: [SeasonSummary]
    /// Next episode air date for a show, or the release date for a movie not out yet. Drives release notifications.
    public var upcoming: UpcomingRelease?
    public init(summary: TitleSummary, tagline: String? = nil, runtimeMinutes: Int? = nil, certification: String? = nil,
                genres: [String] = [], logoPath: String? = nil, cast: [CastMember] = [], trailers: [Trailer] = [],
                seasons: [SeasonSummary] = [], upcoming: UpcomingRelease? = nil) {
        self.upcoming = upcoming
        self.summary = summary
        self.tagline = tagline
        self.runtimeMinutes = runtimeMinutes
        self.certification = certification
        self.genres = genres
        self.logoPath = logoPath
        self.cast = cast
        self.trailers = trailers
        self.seasons = seasons
    }
}

public struct ProviderOffer: Hashable, Codable, Sendable, Identifiable {
    public enum OfferType: String, Codable, Sendable { case flatrate, free, ads, rent, buy }
    public var providerID: Int
    public var name: String
    public var type: OfferType
    public var logoPath: String?
    public var id: String { "\(providerID)-\(type.rawValue)" }
    public init(providerID: Int, name: String, type: OfferType, logoPath: String? = nil) {
        self.providerID = providerID
        self.name = name
        self.type = type
        self.logoPath = logoPath
    }
}

public struct StreamRequest: Sendable {
    public var title: TitleRef
    public var preferredLanguages: [String]
    public var region: String
    public init(title: TitleRef, preferredLanguages: [String] = ["eng"], region: String = "US") {
        self.title = title
        self.preferredLanguages = preferredLanguages
        self.region = region
    }
}

/// Opaque, in-memory only. Never persisted, never logged.
public enum LocatorHint: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case url(URL)
    case torbox(kind: TorBoxKind, itemID: Int, fileID: Int)
    case jellyfin(itemID: String, mediaSourceID: String?)
    public var description: String { "<locator>" }
    public var debugDescription: String { "<locator>" }
}

public struct StreamCandidate: Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Availability: Sendable, Equatable { case playable, unavailable(String) }

    /// Stable per candidate: source plus release identity. Never derived from the URL.
    public var id: String
    public var sourceID: SourceID
    public var sourceKind: SourceKind
    public var title: TitleRef
    public var displayName: String
    public var detailLines: [String]
    public var releaseGroup: String?
    public var sizeBytes: Int64?
    public var claimed: ClaimedFormat
    public var isCached: Bool?
    public var availability: Availability
    public var locatorHint: LocatorHint

    public init(id: String? = nil, sourceID: SourceID, sourceKind: SourceKind = .aiostreams, title: TitleRef, displayName: String,
                detailLines: [String] = [], releaseGroup: String? = nil, sizeBytes: Int64? = nil,
                claimed: ClaimedFormat = ClaimedFormat(), isCached: Bool? = nil, availability: Availability = .playable,
                locatorHint: LocatorHint) {
        self.id = id ?? "\(sourceID.rawValue.uuidString):\(displayName):\(sizeBytes ?? 0)"
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.title = title
        self.displayName = displayName
        self.detailLines = detailLines
        self.releaseGroup = releaseGroup
        self.sizeBytes = sizeBytes
        self.claimed = claimed
        self.isCached = isCached
        self.availability = availability
        self.locatorHint = locatorHint
    }

    public var description: String { "StreamCandidate(\(displayName), \(claimed.badges.joined(separator: " ")))" }
    public var debugDescription: String { description }
}

public struct SubtitleCandidate: Identifiable, Sendable {
    public var id: String
    public var language: String
    public var label: String
    public var url: URL
    public init(id: String, language: String, label: String, url: URL) {
        self.id = id
        self.language = language
        self.label = label
        self.url = url
    }
}

public struct OwnedItem: Identifiable, Sendable, Hashable {
    public var id: String
    public var sourceID: SourceID
    public var title: String
    public var year: Int?
    public var sizeBytes: Int64?
    public var dateAdded: Date?
    public var isReady: Bool
    public var statusText: String?
    public var matched: TitleRef?
    public var files: [LibraryFile]
    public init(id: String, sourceID: SourceID, title: String, year: Int? = nil, sizeBytes: Int64? = nil, dateAdded: Date? = nil,
                isReady: Bool = true, statusText: String? = nil, matched: TitleRef? = nil, files: [LibraryFile] = []) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.year = year
        self.sizeBytes = sizeBytes
        self.dateAdded = dateAdded
        self.isReady = isReady
        self.statusText = statusText
        self.matched = matched
        self.files = files
    }
}

extension OwnedItem {
    public static func == (lhs: OwnedItem, rhs: OwnedItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct LibraryFile: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var sizeBytes: Int64?
    public var locatorHint: LocatorHint
    public init(id: String, name: String, sizeBytes: Int64?, locatorHint: LocatorHint) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.locatorHint = locatorHint
    }
}

public struct PlaybackLocator: Sendable, CustomStringConvertible {
    public var url: URL
    public var headers: [String: String]
    public var expiresAt: Date?
    public init(url: URL, headers: [String: String] = [:], expiresAt: Date? = nil) {
        self.url = url
        self.headers = headers
        self.expiresAt = expiresAt
    }
    public var description: String { "PlaybackLocator(<redacted>)" }
}

public struct PlaybackReport: Sendable {
    public enum Phase: String, Sendable { case start, progress, pause, stop }
    public var title: TitleRef
    public var phase: Phase
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var sessionID: String
    public init(title: TitleRef, phase: Phase, positionSeconds: Double, durationSeconds: Double, sessionID: String) {
        self.title = title
        self.phase = phase
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.sessionID = sessionID
    }
    public var fraction: Double { durationSeconds > 0 ? min(max(positionSeconds / durationSeconds, 0), 1) : 0 }
}

/// One protocol behind every source. Unsupported calls throw `.unsupported`; check `capabilities` first.
public protocol MediaSource: Sendable {
    var id: SourceID { get }
    var kind: SourceKind { get }
    var displayName: String { get }
    var capabilities: SourceCapabilities { get }

    func health() async -> SourceHealth
    func catalogs() async throws -> [CatalogDescriptor]
    func catalogPage(_ catalog: CatalogDescriptor, cursor: PageCursor?) async throws -> Page<TitleSummary>
    func metadata(for title: TitleRef) async throws -> TitleDetail
    func streams(for request: StreamRequest) async throws -> [StreamCandidate]
    func subtitles(for request: StreamRequest) async throws -> [SubtitleCandidate]
    func libraryPage(cursor: PageCursor?) async throws -> Page<OwnedItem>
    func watchProviders(for title: TitleRef, region: String) async throws -> [ProviderOffer]
    /// Turns a candidate into something the player can open. Called at play time only: links are short-lived secrets.
    func resolve(_ hint: LocatorHint) async throws -> PlaybackLocator
    func reportPlayback(_ report: PlaybackReport) async throws
}

public extension MediaSource {
    func health() async -> SourceHealth { .ok }
    func catalogs() async throws -> [CatalogDescriptor] { throw SourceError.unsupported }
    func catalogPage(_ catalog: CatalogDescriptor, cursor: PageCursor?) async throws -> Page<TitleSummary> { throw SourceError.unsupported }
    func metadata(for title: TitleRef) async throws -> TitleDetail { throw SourceError.unsupported }
    func streams(for request: StreamRequest) async throws -> [StreamCandidate] { throw SourceError.unsupported }
    func subtitles(for request: StreamRequest) async throws -> [SubtitleCandidate] { throw SourceError.unsupported }
    func libraryPage(cursor: PageCursor?) async throws -> Page<OwnedItem> { throw SourceError.unsupported }
    func watchProviders(for title: TitleRef, region: String) async throws -> [ProviderOffer] { throw SourceError.unsupported }
    func resolve(_ hint: LocatorHint) async throws -> PlaybackLocator { throw SourceError.unsupported }
    func reportPlayback(_ report: PlaybackReport) async throws { throw SourceError.unsupported }
}
