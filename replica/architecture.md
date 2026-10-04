# Architecture: Lanterna (a clean-room rebuild of Prism's core features)

Inputs: `replica/recon.md`, `replica/features.csv`, `CLAUDE.md`, `docs/phases.md`, `docs/p0-player-spike.md`.
Constraints in CLAUDE.md are fixed. This document does not propose alternatives to them; it fills them in.

Anything marked **(verify)** comes from training knowledge of a third-party API or OS behavior and has not been checked against current docs or a device. Check it at the start of the milestone that uses it.

## Stack

| layer | choice | why |
| --- | --- | --- |
| language / UI | Swift 6 (strict concurrency), SwiftUI, iOS 26 and tvOS 26 | Fixed in CLAUDE.md |
| project | XcodeGen, `project.yml` is source of truth | Fixed |
| packages | `LanternaKit` (models, sources, networking, Keychain, SwiftData, Trakt sync), `LanternaPlayer` (router, Engine A, Engine C) | Fixed; apps stay thin |
| persistence | SwiftData, on-device only, versioned schema from v1 | Fixed. On tvOS it is a cache (see "tvOS storage" below) |
| small durable config | `UserDefaults` for non-secret settings, kept under 64 KB | Only persistent local store tvOS guarantees (500 KB cap) **(verify)** |
| secrets | Keychain, default access group, `kSecAttrAccessibleAfterFirstUnlock`, constant service name `lanterna` | Fixed; never derive from bundle ID |
| networking | `URLSession` async/await, one `HTTPClient` with a redacting logger | No dependency needed |
| media core | One FFmpeg build (libavformat, libavcodec, libswresample) shared by Engine A and C | Fixed ("share one FFmpeg build") |
| Engine C | KSPlayer MEPlayer, pinned to an exact version | Leading candidate per CLAUDE.md; confirm in P0. Prism shipped on KSPlayer until July 2026 (recon) |
| FFmpeg source | The FFmpeg xcframeworks KSPlayer already depends on (kingslay/FFmpegKit, not the archived arthenica FFmpegKit) **(verify)** | Lets A and C share one build with no second FFmpeg |
| localhost HLS server | `Network.framework` `NWListener` bound to 127.0.0.1 | No dependency; ATS already allows local networking |
| pairing transport | `NWListener` / `NWConnection` with Bonjour `_lanterna-pair._tcp` (already in `project.yml`) | No server; no multicast entitlement needed |
| pairing crypto | CryptoKit: X25519, HKDF-SHA256, ChaCha20-Poly1305 | System framework |
| QR | CoreImage `CIQRCodeGenerator` on tvOS; VisionKit `DataScannerViewController` on iOS | System frameworks; camera string already declared |
| logging | `os.Logger` with `privacy: .private` on anything URL-shaped, plus `Redactor` | Secrets never logged |
| tests | Swift Testing / XCTest for packages, XCUITest with `XCUIRemote` for tvOS | Fixed |
| distribution | `make ipa-tvos`, `make ipa-ios`, atvloadly and AltStore | Fixed |

Not used, on purpose: server, CloudKit, iCloud KVS, App Groups, push, Associated Domains, Sign in with Apple, extensions, payments, analytics.

Record every package in `docs/dependencies.md` with exact version and license the moment it is added (KSPlayer and its FFmpeg build are the first, in M0). KSPlayer is expected to be GPL-3.0 and the FFmpeg build may include GPL parts **(verify)**; fine for personal use, but record it.

## Signing limits and what they force

| limit (CLAUDE.md) | design consequence |
| --- | --- |
| Signer rewrites bundle ID; never hardcode bundle ID, team ID, access group | Keychain service is the constant `"lanterna"`, access group omitted. Bonjour type and URL schemes are constants unrelated to bundle ID |
| Keychain items live in the team-prefixed default access group | If the signing Apple ID ever changes, every secret is unreadable. Every source must handle "secret missing" as a normal state that offers **Pair again**, never a crash |
| No iCloud / CloudKit | Cross-device state goes through Trakt only. Non-Trakt config (sources, services, shelves) moves iPhone to Apple TV through QR pairing |
| No App Groups | No shared container. Nothing depends on one |
| No extensions | No Top Shelf, no notification service extension, no widgets |
| No push | Release reminders, if built, are local notifications scheduled while the app runs |
| 7-day profiles, 3 apps per Apple ID | Free accounts also cap App ID creation (10 per 7 days) **(verify)**. Do not churn targets or bundle IDs; keep exactly two app targets |
| P4 deep links | `LSApplicationQueriesSchemes` goes in `project.yml` Info properties so `canOpenURL` works. Plain Info.plist key, no entitlement |

## tvOS storage (the constraint that shapes the schema)

Apple's tvOS guidance: apps get about 500 KB of persistent local storage through `UserDefaults`. Everything else (Caches, and in practice any other directory) can be purged when space runs low. Keychain persists. **(verify on device in M1: confirm where SwiftData's default store lands on tvOS and whether Application Support writes succeed.)**

So on tvOS:

1. **Keychain** holds secrets (persistent).
2. **`DeviceConfig`** (non-secret: source list metadata, subscribed services, region, shelves, player and stream preferences) is one versioned Codable struct, JSON-encoded into `UserDefaults`, budget 64 KB. It is the durable copy. The iPhone can re-send it any time over pairing.
3. **SwiftData** holds caches that can be rebuilt: title metadata, Jellyfin and TorBox indexes, watch-provider lookups, probe records, local progress mirror, sync outbox. The store is created with an explicit URL under `Caches/` on tvOS so purging fails safe instead of crashing. On launch, a missing store is rebuilt from `DeviceConfig` + Keychain + Trakt.
4. The one piece of non-rebuildable state is **unsynced progress** in the outbox. The outbox flushes to Trakt immediately on pause, stop, and backgrounding to keep that window to seconds.

On iOS the same code runs with the store in Application Support, so it simply never gets purged.

## The MediaSource protocol

One protocol, per CLAUDE.md. Sources declare what they can do; unsupported calls have default implementations that throw `.unsupported`, so callers check `capabilities` first.

```swift
// LanternaKit/Sources/Core/MediaSource.swift

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case aiostreams, torbox, jellyfin, tmdb, trakt
}

public struct SourceCapabilities: OptionSet, Sendable, Codable {
    public let rawValue: Int
    public static let catalogs      = Self(rawValue: 1 << 0) // rows for Home
    public static let metadata      = Self(rawValue: 1 << 1) // title / season / episode detail
    public static let streams       = Self(rawValue: 1 << 2) // playable candidates for a title
    public static let subtitles     = Self(rawValue: 1 << 3) // external subtitle files
    public static let library       = Self(rawValue: 1 << 4) // user's own items (TorBox, Jellyfin)
    public static let watchProviders = Self(rawValue: 1 << 5) // TMDB availability
    public static let progressSync  = Self(rawValue: 1 << 6) // Trakt, Jellyfin playstate
    public static let userLists     = Self(rawValue: 1 << 7) // watchlist, favorites, history
}

/// Canonical identity. TMDB-first, like the original; IMDb carried for Stremio-protocol sources.
public struct TitleRef: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case movie, show, episode }
    public var kind: Kind
    public var tmdbID: Int            // for .episode this is the show's TMDB ID
    public var imdbID: String?        // "tt0133093"; required by AIOStreams
    public var season: Int?
    public var episode: Int?
    public var key: String { /* "movie:603", "show:1399", "episode:1399:1:2" */ }
}

public struct StreamRequest: Sendable {
    public var title: TitleRef
    public var preferredLanguages: [String]
    public var region: String
}

public protocol MediaSource: Sendable {
    var id: SourceID { get }                       // UUID wrapper, stable per configured source
    var kind: SourceKind { get }
    var displayName: String { get }
    var capabilities: SourceCapabilities { get }

    func health() async -> SourceHealth            // .ok, .needsCredentials, .unreachable(reason), .rateLimited(until:)

    func catalogs() async throws -> [CatalogDescriptor]
    func catalogPage(_ catalog: CatalogDescriptor.ID, cursor: PageCursor?) async throws -> Page<TitleSummary>
    func metadata(for title: TitleRef) async throws -> TitleDetail
    func streams(for request: StreamRequest) async throws -> [StreamCandidate]
    func subtitles(for request: StreamRequest) async throws -> [SubtitleCandidate]
    func libraryPage(cursor: PageCursor?) async throws -> Page<LibraryItem>
    func watchProviders(for title: TitleRef, region: String) async throws -> [ProviderOffer]

    /// Turns a candidate into something the player can open. Called at play time only,
    /// because TorBox and Jellyfin URLs are short-lived and contain secrets.
    func resolve(_ candidate: StreamCandidate) async throws -> PlaybackLocator
    func reportPlayback(_ event: PlaybackEvent) async throws
}

public struct StreamCandidate: Identifiable, Sendable {
    public var id: StreamFingerprint     // stable hash: source + infohash/fileIdx or server item ID. Never the URL.
    public var sourceID: SourceID
    public var title: TitleRef
    public var displayName: String       // cleaned release name
    public var releaseGroup: String?
    public var sizeBytes: Int64?
    public var claimed: ClaimedFormat    // resolution, dynamic range, codecs, Atmos, as the source *claims* (parsed)
    public var isCached: Bool?           // debrid instant availability
    public var availability: Availability // .playable, .unavailable(reason)
    internal var locatorHint: LocatorHint // opaque, in-memory only; never persisted or logged
}

public struct PlaybackLocator: Sendable {
    public var url: URL                  // in memory only
    public var headers: [String: String] // e.g. Jellyfin auth; redacted in logs
    public var supportsRange: Bool?      // nil until probed
    public var expiresAt: Date?
}
```

`SourceRegistry` (an actor) builds sources from `DeviceConfig` + Keychain, fans out `streams(for:)` across enabled sources concurrently with a per-source timeout and cooldown, and reports progress as `checked n of m` for the auto-select overlay.

### Adapter list

All official, public APIs, with the owner's own keys. Endpoint details are **(verify)** against each service's current docs at the start of M1.

| adapter | capabilities | base / auth | endpoints used | notes |
| --- | --- | --- | --- | --- |
| `AIOStreamsSource` | catalogs, metadata, streams, subtitles | Manifest URL (embeds encrypted config) in Keychain. No other auth | Stremio addon protocol: `GET {base}/manifest.json`, `/catalog/{type}/{id}[/{extra}].json`, `/meta/{type}/{id}.json`, `/stream/{type}/{id}.json`, `/subtitles/{type}/{id}[/{extra}].json`. IDs are IMDb: `tt…` (movie), `tt…:S:E` (episode) | Parse `name`/`description`/`behaviorHints.filename`/`videoSize` into `ClaimedFormat`. Play URLs typically redirect to the TorBox CDN; probe the final URL for Range support. The whole base URL is a secret: log only `aiostreams://<redacted>` |
| `TorBoxSource` | library, streams (for own items) | `https://api.torbox.app/v1/api`, `Authorization: Bearer <key>` | `GET /torrents/mylist`, `/usenet/mylist`, `/webdl/mylist`; `GET /torrents/requestdl` (and usenet/webdl equivalents) for a download link | `requestdl` takes the key as a query parameter **(verify)**: redact query strings in all logs. Map items to TMDB by parsing file names (same conservative rule as Prism: ambiguous stays unmatched) |
| `JellyfinSource` | library, streams, metadata (own items), progressSync, intro markers | `https://<pi>.<tailnet>.ts.net` through Caddy. `Authorization: MediaBrowser Client="Lanterna", Device=…, DeviceId=…, Version=…, Token=…` | `POST /Users/AuthenticateByName`, `/QuickConnect/*`, `GET /Items?Recursive=true&Fields=ProviderIds,…`, `/Items/{id}/PlaybackInfo`, `/Videos/{id}/stream?static=true&mediaSourceId=…`, `POST /Sessions/Playing`, `/Playing/Progress`, `/Playing/Stopped`, media segments for intro/recap | Match by `ProviderIds.Tmdb`/`Imdb` only. Each device gets its own token and DeviceId (see pairing) |
| `TMDBSource` | catalogs, metadata, watchProviders | `https://api.themoviedb.org/3`, v4 read token as Bearer, in Keychain | `/trending/{type}/{window}`, `/discover/{movie,tv}`, `/movie/{id}?append_to_response=external_ids,videos,credits,images,release_dates`, `/tv/{id}?append_to_response=external_ids,…`, `/tv/{id}/season/{n}`, `/search/multi`, `/{movie,tv}/{id}/watch/providers`, `/watch/providers/{movie,tv}?watch_region=` | Source of `imdbID` (external_ids) for AIOStreams. Watch-provider data is attributed to JustWatch by TMDB terms **(verify)**: show attribution in Your Services |
| `TraktSource` | catalogs, userLists, progressSync | `https://api.trakt.tv`, headers `trakt-api-version: 2`, `trakt-api-key: <client id>`, `Authorization: Bearer <access>` | Device code: `POST /oauth/device/code`, poll `POST /oauth/device/token`; refresh `POST /oauth/token`. Sync: `/sync/watchlist`, `/sync/history`, `/sync/playback`, `/sync/favorites`, `/sync/last_activities`, `/shows/{id}/progress/watched`. Scrobble: `POST /scrobble/{start,pause,stop}` | Owner registers their own Trakt app; client ID and secret live in Keychain. Do not assume token lifetime; refresh on 401 and rotate the stored refresh token atomically |

`ServiceDeepLinker` (not a MediaSource: it only reads data): maps a TMDB watch-provider ID to an app-launch strategy from a bundled, hand-maintained `DeepLinkArchive.json`:

```json
{ "providerID": 337, "name": "Disney Plus", "scheme": "disneyplus",
  "level": "app-only | search | title | episode", "template": null, "verifiedOn": null, "notes": "" }
```

There is no subscription API and no public content-ID mapping for most services, so many rows will start as `app-only` or `search`. The P4 gate allows logging the gap per service, and the archive is where that log lives.

## SwiftData schema (v1)

Tables (models): **12**. Access rule: single owner, single process; there is no multi-user access control. Instead, the rule is **no secret ever enters SwiftData or UserDefaults**, enforced by type: model fields never hold `PlaybackLocator`, URLs from sources, or tokens. A unit test scans the model schema for `URL`-typed and `token|key|secret|password`-named attributes and fails if it finds any.

Conventions: every model has `createdAt`/`updatedAt` (`Date`, UTC by nature). Uniqueness via `#Unique`. Deletion rules are explicit. Writes go through `@ModelActor` actors (`LibraryStore`, `IndexStore`, `CacheStore`); views read with `@Query`. Enums are stored as `String` raw values for migration safety.

```swift
// LanternaKit/Sources/Persistence/SchemaV1.swift
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [SourceRecord.self, IndexedItem.self, TitleCache.self, EpisodeCache.self,
         PlaybackProgress.self, LibraryEntry.self, SyncOperation.self,
         StreamChoice.self, ProbeRecord.self, WatchAvailability.self,
         IntroMarker.self, PairedDevice.self]
    }
}

/// Mirror of a configured source. Durable copy lives in DeviceConfig; this exists for relationships and status.
@Model final class SourceRecord {
    #Unique<SourceRecord>([\.sourceID])
    var sourceID: UUID
    var kindRaw: String                // SourceKind
    var displayName: String
    var isEnabled: Bool
    var sortOrder: Int
    var jellyfinServerID: String?      // stable server Id, verified on every connect
    var jellyfinUserID: String?
    var selectedLibraryIDs: [String]
    var lastSyncAt: Date?
    var lastErrorSummary: String?      // redacted, human readable
    @Relationship(deleteRule: .cascade, inverse: \IndexedItem.source) var items: [IndexedItem] = []
    var createdAt: Date; var updatedAt: Date
}

/// One owned file or server item (TorBox, Jellyfin), mapped to TMDB when confident.
@Model final class IndexedItem {
    #Unique<IndexedItem>([\.sourceID, \.externalID])
    #Index<IndexedItem>([\.titleKey], [\.dateAdded])
    var sourceID: UUID
    var externalID: String             // Jellyfin item ID, or TorBox "<kind>:<id>:<fileID>"
    var source: SourceRecord?
    var titleKey: String?              // TitleRef.key, nil when unmatched
    var matchStateRaw: String          // matched | unmatched | ambiguous
    var parsedTitle: String; var parsedYear: Int?
    var season: Int?; var episode: Int?
    var genres: [Int]
    var sizeBytes: Int64?
    var dateAdded: Date
    var statusRaw: String?             // TorBox: cached | downloading | failed
    var createdAt: Date; var updatedAt: Date
}

/// TMDB detail cache. Rebuildable.
@Model final class TitleCache {
    #Unique<TitleCache>([\.titleKey])
    var titleKey: String               // "movie:603" | "show:1399"
    var tmdbID: Int; var kindRaw: String; var imdbID: String?
    var title: String; var originalTitle: String?; var year: Int?
    var overview: String?; var runtimeMinutes: Int?; var certification: String?
    var genres: [Int]
    var posterPath: String?; var backdropPath: String?; var logoPath: String?
    var detailJSON: Data?              // full decoded detail for offline cold launch
    var fetchedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \EpisodeCache.show) var episodes: [EpisodeCache] = []
    var createdAt: Date; var updatedAt: Date
}

@Model final class EpisodeCache {
    #Unique<EpisodeCache>([\.titleKey])
    var titleKey: String               // "episode:1399:1:2"
    var show: TitleCache?
    var season: Int; var episode: Int
    var name: String?; var airDate: Date?      // exact UTC timestamp when known, not a day
    var stillPath: String?; var runtimeMinutes: Int?
    var fetchedAt: Date
    var createdAt: Date; var updatedAt: Date
}

/// Resume position. Local mirror of Trakt /sync/playback; written on every pause/stop.
@Model final class PlaybackProgress {
    #Unique<PlaybackProgress>([\.titleKey])
    #Index<PlaybackProgress>([\.updatedAt])
    var titleKey: String
    var showTMDBID: Int?               // for grouping Continue Watching by show
    var positionSeconds: Double
    var durationSeconds: Double
    var isCompleted: Bool              // >= 90% or credits marker
    var traktPlaybackID: Int64?
    var syncStateRaw: String           // synced | pending | conflict
    var lastStreamID: String?          // StreamFingerprint, to offer "same stream" on resume
    var deviceName: String             // which device wrote it (debug for P5 gate)
    var createdAt: Date; var updatedAt: Date
}

/// Watchlist, favorite, rating, hidden, and each history play.
@Model final class LibraryEntry {
    #Unique<LibraryEntry>([\.kindRaw, \.titleKey, \.playID])
    #Index<LibraryEntry>([\.kindRaw, \.updatedAt])
    var kindRaw: String                // watchlist | favorite | history | rating | hidden
    var titleKey: String
    var playID: String                 // "" for non-history kinds; Trakt history ID or local UUID for plays
    var watchedAt: Date?
    var rating: Int?                   // 1...10
    var hiddenUntil: Date?             // Continue Watching dismissals (~30 days)
    var traktID: Int64?
    var syncStateRaw: String
    var createdAt: Date; var updatedAt: Date
}

/// Outbox for Trakt and Jellyfin writes. Idempotent, retried with backoff. The only non-rebuildable table.
@Model final class SyncOperation {
    #Unique<SyncOperation>([\.idempotencyKey])
    #Index<SyncOperation>([\.nextAttemptAt])
    var idempotencyKey: String         // e.g. "scrobble-stop:episode:1399:1:2:<sessionID>"
    var targetRaw: String              // trakt | jellyfin
    var opRaw: String                  // scrobbleStart | scrobblePause | scrobbleStop | watchlistAdd | ...
    var payload: Data                  // Codable, no secrets
    var attempts: Int
    var nextAttemptAt: Date
    var lastErrorSummary: String?
    var createdAt: Date; var updatedAt: Date
}

/// Remembered stream selection per title ("retain remembered selection").
@Model final class StreamChoice {
    #Unique<StreamChoice>([\.titleKey])
    var titleKey: String
    var streamID: String               // StreamFingerprint
    var sourceID: UUID
    var audioLanguage: String?; var subtitleLanguage: String?
    var createdAt: Date; var updatedAt: Date
}

/// Probe result plus the routing decision. Doubles as the routing log (S29) and P0 evidence.
@Model final class ProbeRecord {
    #Unique<ProbeRecord>([\.streamID, \.probedAt])
    #Index<ProbeRecord>([\.probedAt])
    var streamID: String               // StreamFingerprint, never the URL
    var titleKey: String?
    var probeJSON: Data                // StreamProbe, Codable
    var engineRaw: String              // A | A-direct | C
    var reasons: [String]              // RouteReason raw values
    var outcomeRaw: String             // played | failedOpen | failedMidstream | rerouted
    var failureSummary: String?
    var ttffMillis: Int?
    var probedAt: Date
    var createdAt: Date; var updatedAt: Date
}

/// Lookup archive: TMDB watch providers per title per region.
@Model final class WatchAvailability {
    #Unique<WatchAvailability>([\.titleKey, \.region])
    var titleKey: String
    var region: String                 // ISO 3166-1, e.g. "US"
    var offersJSON: Data               // [ProviderOffer]: providerID, type (flatrate|free|ads|rent|buy)
    var fetchedAt: Date                // TTL 7 days
    var createdAt: Date; var updatedAt: Date
}

@Model final class IntroMarker {
    #Unique<IntroMarker>([\.titleKey, \.kindRaw, \.sourceRaw])
    var titleKey: String
    var kindRaw: String                // intro | recap | credits
    var startSeconds: Double; var endSeconds: Double
    var sourceRaw: String              // jellyfin | user
    var createdAt: Date; var updatedAt: Date
}

/// History of pairings. Holds no keys; pairing keys are ephemeral.
@Model final class PairedDevice {
    #Unique<PairedDevice>([\.deviceID])
    var deviceID: UUID
    var name: String
    var platformRaw: String            // ios | tvos
    var lastPairedAt: Date
    var createdAt: Date; var updatedAt: Date
}
```

**Not in SwiftData, by design:**

- `DeviceConfig` (UserDefaults JSON, versioned): `sources: [SourceConfig]` (id, kind, name, enabled, order, non-secret Jellyfin URLs and IDs), `subscribedServices: [SubscribedService]` (providerID, name, region, showWhenPlaying), `watchRegion`, `shelves: [ShelfConfig]` (title, style, order, hidden, `ShelfQuery` enum: preset / filters / traktList / tmdbList / jellyfinCollection / aiostreamsCatalog), `streamPrefs` (source order, requirements, sort, auto-select, prefer library), `playerPrefs` (audio default, subtitle languages, forced subs, appearance, next-episode lead time, skip intro mode).
- Secrets (Keychain, account names): `torbox.apiKey`, `aiostreams.manifestURL`, `tmdb.readToken`, `trakt.clientID`, `trakt.clientSecret`, `trakt.accessToken`, `trakt.refreshToken`, `trakt.expiresAt`, `jellyfin.<sourceID>.token`, `jellyfin.deviceID`.
- Stream URLs, locators, HLS session tokens: memory only.

**Hard constraints found in recon, enforced in the data layer:**

- One progress row per title (`#Unique titleKey`); last write wins by `updatedAt`, but a newer Trakt row always replaces a local `synced` row, and a local `pending` row is pushed before pulling (see "races").
- Shelf cap of 20 enforced in `DeviceConfig` validation.
- Deleting a source cascades to its `IndexedItem`s. Shelves that depend on it are flagged, not silently broken (Prism shipped exactly this bug).
- Ambiguous matches never get a `titleKey` (`matchState = ambiguous`).

## PlaybackRouter and the probe model

```swift
// LanternaPlayer/Sources/Probe/StreamProbe.swift
public struct StreamProbe: Codable, Sendable {
    public var container: Container            // .matroska, .mp4, .mpegts, .other(String)
    public var durationSeconds: Double?
    public var seekIndex: SeekIndex            // .matroskaCues(count) | .mp4Moov(faststart: Bool) | .none
    public var byteSource: ByteSourceInfo      // supportsRange, contentLength, finalHost (redacted), redirects
    public var bitRate: Int?
    public var video: VideoInfo?
    public var audio: [AudioTrackInfo]
    public var subtitles: [SubtitleTrackInfo]
    public var chapters: [Chapter]
    public var probeMillis: Int
}

public struct VideoInfo: Codable, Sendable {
    public var codec: VideoCodec               // .h264, .hevc, .av1, .vc1, .mpeg2, .vp9, .other(String)
    public var profile: String?                // "High", "High 10", "Main 10"
    public var level: Int?
    public var bitDepth: Int
    public var width: Int; public var height: Int
    public var frameRate: Rational             // exact, e.g. 24000/1001
    public var interlaced: Bool
    public var colorPrimaries: String?; public var transfer: String?; public var matrix: String?
    public var dynamicRange: DynamicRange
}

public enum DynamicRange: Codable, Sendable, Hashable {
    case sdr, hdr10, hdr10Plus, hlg
    case dolbyVision(DoviConfig)               // read from AV_PKT_DATA_DOVI_CONF side data
}
public struct DoviConfig: Codable, Sendable, Hashable {
    public var profile: Int                    // 5, 7, 8
    public var level: Int
    public var blSignalCompatibilityID: Int    // 1 (HDR10), 2 (SDR), 4 (HLG), 6 ...
    public var rpuPresent: Bool; public var elPresent: Bool
}

public struct AudioTrackInfo: Codable, Sendable {
    public var index: Int
    public var codec: AudioCodec               // .aac, .ac3, .eac3, .truehd, .dts, .dtsHDMA, .dtsHRA, .flac, .opus, .mp3, .pcm, .other
    public var channels: Int; public var layout: String?
    public var hasAtmos: Bool                  // EAC3 JOC or TrueHD Atmos profile flag
    public var language: String?; public var title: String?
    public var isDefault: Bool; public var isCommentary: Bool; public var isAudioDescription: Bool
}

public struct SubtitleTrackInfo: Codable, Sendable {
    public var index: Int
    public var format: SubtitleFormat          // .srt, .ass, .ssa, .webvtt, .movText, .pgs, .vobsub, .dvb
    public var language: String?; public var title: String?
    public var isForced: Bool; public var isDefault: Bool
    public var isImageBased: Bool { /* pgs, vobsub, dvb */ }
}
```

```swift
// LanternaPlayer/Sources/Routing/PlaybackRouter.swift
public enum EngineID: String, Codable, Sendable {
    case aDirect = "A-direct"   // MP4 AVPlayer can open as-is: zero remux work (corpus #6)
    case aRemux  = "A"          // on-device remux to fMP4 HLS
    case c       = "C"          // FFmpeg renderer (KSPlayer MEPlayer)
}

public enum RouteReason: String, Codable, Sendable {
    // to C
    case noSeekIndex, noRangeSupport, unsupportedContainer
    case hi10p, av1NoHardwareDecode, vc1, mpeg2, vp9, interlaced, unsupportedVideo
    case imageSubtitleRequired          // default/forced/preferred-language track is PGS/VobSub
    case userSelectedImageSubtitle      // mid-playback reroute
    case engineAFailedOpen, engineAFailedMidstream
    case probeFailed
    // informational, still A
    case audioTranscodeDTS, audioTranscodeTrueHD, audioTranscodeOther
    case dvProfile7AsHDR10              // P7 played as HDR10 base layer (no RPU rewrite in v1)
    case dvProfile82AsSDR
    case textSubtitlesToWebVTT
}

public struct AudioPlan: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case copy, transcodeEAC3_51, transcodeAAC_Stereo, drop }
    public var trackIndex: Int; public var action: Action
}

public struct RoutingDecision: Codable, Sendable {
    public var engine: EngineID
    public var reasons: [RouteReason]
    public var audioPlan: [AudioPlan]
    public var webVTTTracks: [Int]
    public var imageSubtitleTracks: [Int]       // offered via custom menu item -> reroute to C
    public var displayCriteria: DisplayCriteriaHint // frame rate + dynamic range for C (A gets it from AVKit)
}

public struct RoutingContext: Sendable {
    public var preferences: PlayerPreferences   // audio/subtitle language, forced subs
    public var hardware: HardwareCapabilities   // VTIsHardwareDecodeSupported(AV1), DV display support
    public var forcedEngine: EngineID?          // P0 harness and diagnostics only
}

public protocol RoutingPolicy: Sendable {
    func decide(_ probe: StreamProbe, context: RoutingContext) -> RoutingDecision   // pure, unit-tested
}

public protocol PlaybackEngine: AnyObject {
    var id: EngineID { get }
    @MainActor func makeSession(locator: PlaybackLocator, probe: StreamProbe,
                                decision: RoutingDecision, start: Double) async throws -> PlaybackSession
}

@MainActor public protocol PlaybackSession: AnyObject {
    var viewController: UIViewController { get }      // AVPlayerViewController for A; custom for C
    var events: AsyncStream<PlaybackEvent> { get }    // ready(ttff), progress, stalled, failed, ended, trackChanged
    var currentTime: Double { get }
    func play(); func pause(); func seek(to: Double) async
    func stop() async
}

public actor PlaybackRouter {
    public init(prober: StreamProber, policy: RoutingPolicy, engines: [EngineID: PlaybackEngine],
                probeCache: ProbeCache, log: RoutingLog)
    /// Probe (cached by StreamFingerprint), decide, log, open. If A fails to open or fails mid-stream,
    /// reopen in C at the current position and log the reroute. Never silently.
    public func open(_ candidate: StreamCandidate, locator: PlaybackLocator,
                     start: Double, context: RoutingContext) async throws -> PlaybackSession
    @MainActor public func reroute(_ session: PlaybackSession, to engine: EngineID,
                                   reason: RouteReason) async throws -> PlaybackSession
}
```

**Policy (v1, the thing P0 confirms or changes):**

1. Probe fails, no Range support, or no seek index (MKV without Cues) → **C**.
2. Container MP4 with `moov`, H.264 8-bit or HEVC, audio all AAC/AC3/EAC3, no image subs needed → **A-direct** (AVPlayer opens the URL itself).
3. Video H.264 Hi10P, AV1 without hardware decode (Apple TV 4K is expected to lack AV1 decode **(verify)**), VC-1, MPEG-2, VP9, or interlaced → **C**.
4. Default, forced, or preferred-language subtitle exists only as an image format → **C**.
5. Otherwise MKV with Cues → **A** with: video stream copy; audio plan copy AAC/AC3/EAC3, DTS/DTS-HD/TrueHD → EAC3 5.1, FLAC/Opus/PCM → EAC3 5.1 if more than 2 channels else AAC; text subtitles → WebVTT; image subtitle tracks exposed through a custom transport-bar menu item ("More subtitles") that triggers `reroute(to: .c, reason: .userSelectedImageSubtitle)` at the current position.
6. DV P7 → A as HDR10 (strip DV config). DV P8.2 → A as SDR. Both logged.
7. Every decision is written to `ProbeRecord` and `os.Logger` (category `routing`) with the probe summary. URLs never appear.

**Engine A internals (LanternaPlayer/EngineA):**

| part | job |
| --- | --- |
| `RemoteByteSource` | URLSession range reads with read-ahead window and small LRU block cache; follows redirects once and pins the final URL for the session |
| `AVIOBridge` | Custom `AVIOContext` read/seek callbacks. FFmpeg calls these synchronously, so the demuxer runs on its **own dedicated `Thread`** that blocks on the byte source, never on the Swift concurrency pool (blocking the cooperative pool deadlocks) |
| `SegmentPlanner` | Reads Matroska Cues → keyframe timestamps → segment boundaries (target ~6 s, cut only on keyframes) → full VOD playlist before playback starts |
| `SegmentMuxer` | libavformat mp4 muxer in fragmented mode (`frag_keyframe+empty_moov+default_base_moof`). Writes one init segment per rendition and media segments on request. Must emit `hvc1` (not `hev1`) sample entries and carry `dvcC`/`dvvC` for DV **(verify the FFmpeg version writes these in fMP4)** |
| `AudioTranscoder` | libavcodec decode DTS/TrueHD → libswresample → FFmpeg native `eac3` encoder at 5.1 / 640 kbps |
| `SubtitleConverter` | SRT/ASS → WebVTT with `X-TIMESTAMP-MAP`; ASS styling reduced to WebVTT-safe cues |
| `LocalHLSServer` | `NWListener` on 127.0.0.1, random port, per-session 128-bit token as first path component; serves only that session; stops with it |
| `PlaylistWriter` | Master playlist with separate audio renditions (`EXT-X-MEDIA TYPE=AUDIO`, language, name, `CHANNELS="16/JOC"` for Atmos) and subtitle renditions. Video `CODECS`/`SUPPLEMENTAL-CODECS`/`VIDEO-RANGE` set from the probe (e.g. P5 `dvh1.05.xx`, P8.1 `hvc1…` with `SUPPLEMENTAL-CODECS="dvh1.08.xx/db1p"`, `VIDEO-RANGE=PQ`) **(verify against Apple's HLS authoring spec)** |
| `EngineASession` | `AVPlayerViewController` with `appliesPreferredDisplayCriteriaAutomatically = true`, chapters via `AVTimedMetadataGroup` navigation markers, `transportBarCustomMenuItems` for "More subtitles", Now Playing via AVKit |

**Localhost HLS routes** (session token `T`):

| method path | does |
| --- | --- |
| `GET /T/master.m3u8` | master playlist with all renditions |
| `GET /T/v/index.m3u8` | video media playlist (VOD, full segment list) |
| `GET /T/v/init.mp4`, `/T/v/{n}.m4s` | video init and segment n, generated on request, cached a few ahead |
| `GET /T/a/{track}/index.m3u8`, `/init.mp4`, `/{n}.m4s` | audio rendition (copied or transcoded) |
| `GET /T/s/{track}/index.m3u8`, `/{n}.vtt` | WebVTT rendition |
| anything else, or wrong token | 404, logged without the path |

**Engine C (LanternaPlayer/EngineC):** wraps KSPlayer MEPlayer. Built by hand: SwiftUI transport bar copying tvOS behavior (clickpad scrub, swipe-down info panel with audio/subtitle/chapters, Siri rewind "what did they say"), `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` (including dedicated fast-forward/rewind commands), `AVDisplayManager.preferredDisplayCriteria` from `DisplayCriteriaHint`, waiting for `isDisplayModeSwitchInProgress` to clear before first frame, and PiP through `AVPictureInPictureController.ContentSource` when the renderer uses `AVSampleBufferDisplayLayer` **(verify KSPlayer exposes this)**.

## The QR pairing protocol (iPhone → Apple TV)

Goal: move secrets and `DeviceConfig` to the Apple TV without typing, without a server, and without trusting the network. The QR code is the trust anchor: anything that did not see the screen cannot decrypt.

**Roles:** Apple TV = receiver (shows QR, listens). iPhone = sender (scans, connects, sends).

**1. Receiver setup (tvOS, S42/S45)**

- Generate ephemeral X25519 key pair `(tvSK, tvPK)`, random 16-byte `pairSecret`, random 8-byte `sid`.
- Start `NWListener` (TCP, random port), advertise Bonjour `_lanterna-pair._tcp` with name `Lanterna-<sid hex prefix>` and TXT `v=1`.
- Show QR (and a 6-digit fallback code = first 20 bits of `SHA256(sid‖tvPK)`, for visual confirmation only):

```
lanterna-pair:v1?sid=<b64url>&pk=<b64url 32B>&ps=<b64url 16B>&h=<IPv4 or IPv6>&p=<port>&exp=<unix seconds>
```

`h`/`p` let the phone connect by unicast when mDNS is blocked (Pi and Apple TV on different UniFi VLANs, per `ops/atvloadly-pi.md`). Expiry: 5 minutes. Then regenerate everything.

**2. Sender connects (iOS, S28)**

- Scan QR (VisionKit). Reject if expired or `v` unknown.
- Try `NWConnection` to `h:p`; in parallel browse Bonjour for `Lanterna-<sid prefix>`; use whichever connects first.
- Generate ephemeral `(phSK, phPK)`.

**3. Handshake (length-prefixed binary frames over TCP)**

```
→ HELLO   { v:1, sid, phPK, deviceName, nonceP (16B) }                            plaintext
   both:  shared = X25519(own SK, other PK)
          K = HKDF-SHA256(ikm: shared, salt: pairSecret,
                          info: "lanterna-pair-v1" ‖ sid ‖ tvPK ‖ phPK ‖ nonceP ‖ nonceT, 32B)
← WELCOME { nonceT (16B), box_K("tv-ok" ‖ transcriptHash) }                       sealed
→ BUNDLE  { box_K(PairingBundle JSON), seq=1 }                                    sealed
← RESULT  { box_K(PairingResult JSON), seq=2 }                                    sealed
   close; receiver stops listener, zeroes tvSK, pairSecret, K
```

`box_K` = ChaCha20-Poly1305 with key K, nonce derived from `seq` and direction, AAD = `sid ‖ seq ‖ direction`. In `WELCOME`, `nonceT` travels in plaintext beside the sealed box; the phone reads it, derives K, then opens the box. `nonceT` is also bound into K, so altering it breaks decryption. A machine on the network that never saw the QR lacks `pairSecret` and the authentic `tvPK`, so it cannot derive K, forge `WELCOME`, or read `BUNDLE`.

**4. Consent before sending (iPhone)**

The phone shows exactly what will be sent, each item with a toggle, and the 6-digit code to compare with the TV. Nothing is sent until the owner confirms.

**5. Payload**

```swift
struct PairingBundle: Codable {
    var version = 1
    var sentAt: Date
    var fromDeviceName: String
    var config: DeviceConfig?                 // non-secret
    var secrets: [PairingSecret]
}
enum PairingSecret: Codable {
    case torboxAPIKey(String)
    case aiostreamsManifestURL(String)
    case tmdbReadToken(String)
    case traktAppCredentials(clientID: String, clientSecret: String)   // NOT user tokens
    case jellyfin(sourceID: UUID, serverURL: String, remoteURL: String?, quickConnect: Bool)
}
struct PairingResult: Codable { var applied: [String: ItemStatus] }  // per item: ok | failed(reason) | skipped
```

Two deliberate omissions:

- **No Trakt user tokens.** Trakt rotates refresh tokens on use **(verify)**, so two devices sharing one token pair would log each other out. The TV gets the app credentials and then signs in itself with the device code (F11, S41). That costs the owner one phone approval and avoids a token race.
- **No Jellyfin token.** Jellyfin binds tokens to a DeviceId. After receiving the bundle the TV calls `/QuickConnect/Initiate`, sends the code back to the phone **over the same sealed channel** (an extra `QC_CODE`/`QC_DONE` frame pair), and the phone, already signed in, calls `/QuickConnect/Authorize`. The TV gets its own token. If Quick Connect is disabled on the server, the phone asks for the Jellyfin password once, puts it in the sealed bundle, the TV exchanges it via `AuthenticateByName`, and discards it. The password is never stored on either device.

**6. Receiver applies**

Writes secrets to Keychain, merges `DeviceConfig` (incoming wins per field, shelves replaced as a set), rebuilds `SourceRegistry`, records `PairedDevice`, shows a summary. Partial failures are reported per item, and the rest still applies.

**Abuse limits:** one connection at a time; three failed handshakes → regenerate QR; listener runs only while the pairing screen is visible (tvOS cannot listen in the background anyway, per recon). Local Network permission prompt appears on first use on both devices.

**Tests:** the handshake and framing live in `LanternaKit/Pairing` as pure functions over byte buffers, unit-tested with known keys, plus a loopback `NWListener` integration test that runs on the macOS host via `swift test`.

## External calls by flow

Only official, public APIs with the owner's keys. No Prism endpoints, ever.

| call | does | who | input | output | flow |
| --- | --- | --- | --- | --- | --- |
| TMDB trending / discover | Home rows | both apps | page, filters | titles | F02, F16 |
| AIOStreams catalog | Home rows from addon catalogs | both | catalog id, extra | Stremio metas | F02 |
| TMDB detail + external_ids | detail page, IMDb ID for streams | both | tmdb id | detail | F02, F03 |
| AIOStreams stream | stream candidates | both | IMDb id (+S:E) | Stremio streams | F01-F03 |
| TorBox mylist | library | both | — | items | F14 |
| TorBox requestdl | playable link at play time | both | item, file | URL (secret) | F14 |
| Jellyfin Items / PlaybackInfo / stream | library + playback | both | item id | items, media sources, URL | F15 |
| Jellyfin Sessions/Playing* | progress back to server | both | position | — | F15 |
| TMDB watch providers | lookup archive | both | tmdb id, region | offers | F07 |
| Trakt device code + token | sign-in | tvOS (and iOS) | client id | tokens | F11 |
| Trakt scrobble start/pause/stop | live progress | both | title, progress % | ack | F04, F12 |
| Trakt sync playback / history / watchlist / last_activities | pull and push library | both | since | entries | F12, F13 |
| AIOStreams subtitles | external subs | both | IMDb id | subtitle URLs | F06 |

**Jobs** (in-app only; no server, no push):

| job | when | does |
| --- | --- | --- |
| `TraktSync.pull` | launch, foreground, every 5 min while active, after any write | `GET /sync/last_activities`, then pull only changed sections |
| `Outbox.flush` | immediately after enqueue, on reachability change, on foreground, before background | send `SyncOperation`s in order with exponential backoff |
| `IndexSync.jellyfin` | launch, daily, manual | incremental `Items` query by `MinDateLastSaved` **(verify)** |
| `IndexSync.torbox` | launch, on Library open, manual | refresh `mylist`, re-match new items |
| `AvailabilityRefresh` | on detail open if older than 7 days | refresh `WatchAvailability` |
| `CachePrune` | launch | drop `TitleCache` over 30 days, `ProbeRecord` over 500 rows |

## The parts that bite

- **tvOS storage:** SwiftData on tvOS may be purged. Covered above; verify on device in M1.
- **Secrets in URLs:** AIOStreams base URL, TorBox `requestdl` query, Jellyfin `api_key` query, and resolved CDN links all carry secrets. One `Redactor` strips query strings and replaces AIOStreams paths with `<redacted>` before any log line. `os.Logger` interpolations default to `.private`. A test greps log output from fixture runs for known fake secrets.
- **FFmpeg plus Swift 6 concurrency:** AVIO callbacks block. Demux and mux run on dedicated threads with explicit hand-off to async code. Never call blocking FFmpeg from an actor or the cooperative pool.
- **Range support and redirects:** debrid links redirect to a CDN, and some hosts ignore `Range`. Probe the final URL. No Range → C, which can still stream linearly.
- **Huge files:** 4K remuxes run 50 to 80 GB. Never download whole; bounded read-ahead; memory ceiling checked in P0.
- **Subtitles inside MKV are interleaved** with video. WebVTT segments for time range X can only be produced by demuxing range X. AVPlayer may request subtitle segments ahead of video, so the segment cache must be shared across renditions and demux runs per time range, not per rendition.
- **Idempotency:** scrobble `stop` retried after a timeout can double-count a play. Every outbox op has an `idempotencyKey`; Trakt `409 Conflict` on scrobble is treated as success **(verify)**.
- **Races (P5 gate):** iPhone stops at 41:10, Apple TV opens Continue Watching 5 s later. The phone flushes `scrobble/pause` before backgrounding; the TV pulls `/sync/playback` on foreground before showing Continue Watching, and Quick Play re-reads progress right before starting (Prism shipped a "resumes at 0:00" bug from reading too early). Conflict rule: newest `updatedAt` wins; a local `pending` row is pushed before pulling.
- **Time zones:** air dates as exact UTC timestamps from TMDB/Trakt; "Today" and "airs Saturday" computed in the device time zone and locale at render time.
- **Rate limits:** Trakt and TMDB both rate-limit **(verify current numbers)**. One `HTTPClient` with per-host token buckets, `Retry-After` honored, and per-source cooldown after repeated failure (shown as "unavailable", not silently dropped).
- **Numbering:** anime absolute numbering and TMDB vs TVDB season splits break `S:E` lookups on AIOStreams. v1 uses TMDB numbering and logs misses; mapping is a could-have.
- **Keychain after re-sign:** a changed signing Apple ID orphans every secret. Treat missing secrets as "pair again".
- **Search:** TMDB `/search/multi` only; no local full-text index needed.
- **Offline:** iPhone only (downloads are a could-have). tvOS assumes network.
- **Multi-tenancy, GDPR, email, payments, webhooks:** not applicable.

## Build order

The phases and gates in `docs/phases.md` are fixed. Milestones map onto them. M0 is everything P0 needs and nothing more.

### M0: P0 player spike (tvOS only, physical Apple TV)

Goal: fill `docs/p0-results.md` and confirm or change the engine strategy.

- `project.yml`: keep both app targets, add `Packages/LanternaPlayer` and a minimal `Packages/LanternaKit` (Keychain + HTTPClient + Redactor + TorBox `requestdl` only). Run `xcodegen generate`.
- Pin KSPlayer and its FFmpeg build; record both in `docs/dependencies.md`.
- LanternaPlayer: `RemoteByteSource`, `AVIOBridge`, `StreamProber`, `RoutingPolicy` (with unit tests over hand-written `StreamProbe` fixtures), `PlaybackRouter`, Engine A (`SegmentPlanner`, `SegmentMuxer`, `AudioTranscoder`, `SubtitleConverter`, `LocalHLSServer`, `PlaylistWriter`, `EngineASession`), Engine A-direct, Engine C (KSPlayer wrapper with minimal transport, Now Playing, display criteria).
- tvOS **spike harness** screen (Apps/tvOS, debug only): a list of the corpus, "Play in A", "Play in C", "Auto", and an on-screen results table. Measures TTFF, 10 scripted random seeks (median, p90), mode-switch observed (`AVDisplayManager`), memory peak, dropped-frame/stall events. Results also go to `os.Logger` (category `p0`) as one JSON line per run.
- Corpus: `Spike/corpus.local.json` (gitignored) lists TorBox item and file IDs plus the profile label for each of the 10 streams (add an 11th: DV Profile 7, per recon). TorBox key entered once on the TV with the iPhone keyboard and stored in Keychain. Fresh links are requested at play time.
- Run from Xcode directly to the paired Apple TV with the free Personal Team for fast iteration (debugger, Console, Instruments). Do one final `make ipa-tvos` → atvloadly install to confirm the signed IPA behaves the same.
- Manual on-TV checks per stream: DV/HDR mode on the TV, Atmos indicator on the receiver (expect PCM/MAT, not bitstream; see recon finding 4), subtitles, native features, A/V drift at 10 min.
- Gate: per `docs/p0-player-spike.md`. Record the routing decision for each stream in `docs/p0-results.md`.

### M1: P1 LanternaKit

- `MediaSource`, `TitleRef`, `SourceRegistry`, `HTTPClient` (rate limits, retry, redaction), Keychain store.
- Adapters: TMDB, AIOStreams, TorBox (full), Jellyfin (auth, index, playback info), Trakt (device code, sync read). Recorded fixtures in `Tests/Fixtures` with secrets and file URLs scrubbed.
- SwiftData `SchemaV1` + migration plan, `@ModelActor` stores, `DeviceConfig`. Verify the tvOS store location and purge behavior on the device.
- Gate: catalogs, meta, and streams resolve against fixtures and the live manifest.

### M2: vertical slice (P2 start, tvOS)

The core loop end to end, ugly: S30 Home (one TMDB row + one AIOStreams catalog row) → S32 detail → S36 picker with auto-select → router → S38 player → progress written locally → S30 Continue Watching. Trakt device-code login (S41) so progress has somewhere to go. Proves the whole stack on the real TV.

### M3: P2 must-haves (tvOS)

S30-S43 per `features.csv` must rows: show detail with Smart Resume and season focus rules, See All, Search, Library, Settings, stream picker grouping and badges, Up Next countdown, all tvOS focus rules listed in recon, both engines reachable from the UI. Gate: browse to play using only the Siri Remote.

### M4: P3 iOS, TorBox, Jellyfin, pairing

iOS screens S01-S24 (must rows), S26-S28; TorBox library on both; Jellyfin source on both; QR pairing (S28 ↔ S42/S45) including Quick Connect relay; first-run on TV without typing. Gate: same library on both devices; credentials reach tvOS without typing.

### M5: P4 subscribed services

S18 Your Services, `WatchAvailability` lookup archive, `DeepLinkArchive.json`, `LSApplicationQueriesSchemes` in `project.yml`, "Open in" cards in S08/S36/S09/S37. Gate: every service the owner pays for opens the right title, or the gap is logged per service in the archive.

### M6: P5 Trakt sync

Scrobble, outbox, `/sync/playback` pull-before-show, history, watchlist, favorites, Continue Watching rules (paused items + next unwatched episode, ~30-day dismissals). Gate: start on iPhone, resume on Apple TV within 10 s of the stop point.

### Then

Should-haves by area (streams filters and source order, trailers, cast, Coming Soon, intro skip from Jellyfin markers, quiet reconnect, PiP on iPhone, diagnostics S29), then could-haves. `/replica-test` full pass and `/replica-diff` per `docs/phases.md`. Fixes from `/replica-entrepreneur` (optional) become P2-P5 acceptance criteria.

## Summary

- Stack: Swift 6 / SwiftUI on iOS and tvOS 26, XcodeGen, LanternaKit + LanternaPlayer, SwiftData (cache-first on tvOS) + UserDefaults config + Keychain, KSPlayer and one shared FFmpeg build, Network.framework and CryptoKit for localhost HLS and pairing.
- SwiftData models: 12. External APIs: 5 services. Localhost HLS routes: 6. Pairing frames: 6.
- Riskiest: (1) Engine A keeping Dolby Vision through fMP4 HLS on the real Apple TV, (2) Engine C's hand-built native-feeling transport, (3) tvOS local storage being purgeable with no iCloud fallback.
- Next: M0, the P0 spike. `/replica-design` can run in parallel because it touches no player code, but `/replica-build` waits for the P0 gate.
