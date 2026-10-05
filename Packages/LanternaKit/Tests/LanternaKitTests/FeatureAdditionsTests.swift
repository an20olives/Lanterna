import Foundation
import Testing
@testable import LanternaKit

struct JellyfinFailoverTests {
    static let primary = URL(string: "https://pi.local:8920")!
    static let remote = URL(string: "https://pi.tailnet.ts.net")!
    static let device = JellyfinDevice(deviceID: "D", deviceName: "TV", version: "0.1")

    func client(primaryDown: Bool, remoteDown: Bool = false) -> (JellyfinClient, ScriptedTransport) {
        struct Offline: Error {}
        final class Box: @unchecked Sendable { var hosts: [String] = [] }
        let transport = ScriptedTransport { request in
            let host = request.url?.host() ?? ""
            if (host == "pi.local" && primaryDown) || (host == "pi.tailnet.ts.net" && remoteDown) {
                return .init(status: -1, body: "")      // signalled below as a network failure
            }
            return .init(body: #"{"Id":"srv","ServerName":"Home","Version":"10.10.0"}"#)
        }
        let failing = FailingHostTransport(inner: transport, failing: Set([primaryDown ? "pi.local" : "", remoteDown ? "pi.tailnet.ts.net" : ""]))
        return (JellyfinClient(baseURLs: [Self.primary, Self.remote], device: Self.device, token: "T", userID: "U",
                               http: HTTPClient(transport: failing, maxRetries: 0, sleep: { _ in })), transport)
    }

    struct FailingHostTransport: HTTPTransport {
        let inner: ScriptedTransport
        let failing: Set<String>
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if let host = request.url?.host(), failing.contains(host) { throw URLError(.cannotConnectToHost) }
            return try await inner.data(for: request)
        }
    }

    @Test func fallsBackToTheRemoteAddressWhenThePrimaryIsDown() async throws {
        let (client, transport) = client(primaryDown: true)
        let info = try await client.publicInfo()
        #expect(info.serverName == "Home")
        #expect(transport.requests.last?.url?.host() == "pi.tailnet.ts.net")
        #expect(client.activeBaseURL.host() == "pi.tailnet.ts.net")
        // The working address sticks, so the next call does not retry the dead one.
        _ = try await client.publicInfo()
        #expect(transport.requests.suffix(1).allSatisfy { $0.url?.host() == "pi.tailnet.ts.net" })
    }

    @Test func staysOnThePrimaryWhenItWorks() async throws {
        let (client, transport) = client(primaryDown: false)
        _ = try await client.publicInfo()
        #expect(transport.requests.allSatisfy { $0.url?.host() == "pi.local" })
    }

    @Test func failsWhenEveryAddressIsDown() async {
        let (client, _) = client(primaryDown: true, remoteDown: true)
        await #expect(throws: SourceError.self) { _ = try await client.publicInfo() }
    }

    @Test func streamURLUsesTheActiveAddress() async throws {
        let (client, _) = client(primaryDown: true)
        _ = try await client.publicInfo()
        #expect(client.streamURL(itemID: "abc", mediaSourceID: "m").host() == "pi.tailnet.ts.net")
    }
}

struct SegmentTests {
    static let body = """
    {"Items":[{"Id":"1","ItemId":"abc","Type":"Intro","StartTicks":300000000,"EndTicks":900000000},
              {"Id":"2","ItemId":"abc","Type":"Recap","StartTicks":0,"EndTicks":200000000},
              {"Id":"3","ItemId":"abc","Type":"Outro","StartTicks":30000000000,"EndTicks":32000000000},
              {"Id":"4","ItemId":"abc","Type":"Commercial","StartTicks":1,"EndTicks":2}],"TotalRecordCount":4}
    """

    @Test func segmentsDecodeAndKeepSkippableTypesOnly() async throws {
        let transport = ScriptedTransport.routes([("/MediaSegments/abc", Self.body)])
        let client = JellyfinClient(baseURL: URL(string: "https://pi.ts.net")!, device: JellyfinDevice(deviceID: "D", deviceName: "TV", version: "0.1"),
                                    token: "T", userID: "U", http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in }))
        let segments = try await client.segments(itemID: "abc")
        #expect(segments.map(\.kind) == [.recap, .intro, .outro])
        #expect(segments.first { $0.kind == .intro }?.start == 30)
        #expect(segments.first { $0.kind == .intro }?.end == 90)
    }

    @Test func serversWithoutTheEndpointGiveNoSegments() async throws {
        let transport = ScriptedTransport { _ in .init(status: 404, body: "") }
        let client = JellyfinClient(baseURL: URL(string: "https://pi.ts.net")!, device: JellyfinDevice(deviceID: "D", deviceName: "TV", version: "0.1"),
                                    token: "T", userID: "U", http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in }))
        #expect(try await client.segments(itemID: "abc").isEmpty)
    }

    @Test func trackerFindsTheActiveSegmentWithAMargin() {
        let segments = [MediaSegment(kind: .intro, start: 30, end: 90), MediaSegment(kind: .outro, start: 3000, end: 3200)]
        #expect(SegmentTracker.active(at: 10, in: segments) == nil)
        #expect(SegmentTracker.active(at: 30.5, in: segments)?.kind == .intro)
        #expect(SegmentTracker.active(at: 89, in: segments)?.kind == .intro)
        #expect(SegmentTracker.active(at: 89.8, in: segments) == nil, "last half second is not worth a button")
        #expect(SegmentTracker.active(at: 3100, in: segments)?.kind == .outro)
        #expect(MediaSegment(kind: .intro, start: 0, end: 1).skipLabel == "Skip Intro")
        #expect(MediaSegment(kind: .outro, start: 0, end: 1).skipLabel == "Skip Credits")
    }
}

struct PersonAndListTests {
    func client(_ table: [(match: String, body: String)]) -> TMDBClient {
        TMDBClient(readToken: "T", http: HTTPClient(transport: ScriptedTransport.routes(table), maxRetries: 0, sleep: { _ in }))
    }

    @Test func personPageHasBioAndFilmographySortedByPopularity() async throws {
        let body = """
        {"id":6384,"name":"Keanu Reeves","biography":"Canadian actor.","profile_path":"/k.jpg","birthday":"1964-09-02","place_of_birth":"Beirut",
         "combined_credits":{"cast":[
           {"id":604,"media_type":"movie","title":"The Matrix Reloaded","release_date":"2003-05-15","poster_path":"/r.jpg","vote_count":9000,"popularity":50},
           {"id":603,"media_type":"movie","title":"The Matrix","release_date":"1999-03-30","poster_path":"/m.jpg","vote_count":20000,"popularity":80},
           {"id":9999,"media_type":"tv","name":"Talk Show Cameo","first_air_date":"2010-01-01","poster_path":null,"vote_count":3,"popularity":1},
           {"id":603,"media_type":"movie","title":"The Matrix","release_date":"1999-03-30","poster_path":"/m.jpg","vote_count":20000,"popularity":80}]}}
        """
        let person = try await client([("/person/6384", body)]).person(id: 6384)
        #expect(person.name == "Keanu Reeves")
        #expect(person.biography == "Canadian actor.")
        #expect(person.credits.map(\.title) == ["The Matrix", "The Matrix Reloaded", "Talk Show Cameo"], "deduplicated, most popular first")
    }

    @Test func genresAndTMDBListsDecode() async throws {
        let c = client([("/genre/movie/list", #"{"genres":[{"id":28,"name":"Action"},{"id":35,"name":"Comedy"}]}"#),
                        ("/list/8", #"{"id":8,"name":"Best Of","items":[{"id":603,"media_type":"movie","title":"The Matrix","release_date":"1999-03-30"},{"id":1399,"media_type":"tv","name":"GoT","first_air_date":"2011-04-17"}]}"#)])
        let genres = try await c.genres(kind: .movie)
        #expect(genres.map(\.name) == ["Action", "Comedy"])
        let list = try await c.list(id: 8)
        #expect(list.map(\.title) == ["The Matrix", "GoT"])
        #expect(list[1].ref.kind == .show)
    }

    @Test func discoverShelfQueryBuildsFilters() {
        let query = ShelfQuery.discover(DiscoverFilters(kind: .movie, genre: 28, yearFrom: 2010, yearTo: 2020, minRating: 7.5, language: "ja", sort: "vote_average.desc"))
        guard case .discover(let f) = query else { Issue.record("wrong case"); return }
        let params = f.parameters
        #expect(params["with_genres"] == "28")
        #expect(params["primary_release_date.gte"] == "2010-01-01")
        #expect(params["primary_release_date.lte"] == "2020-12-31")
        #expect(params["vote_average.gte"] == "7.5")
        #expect(params["with_original_language"] == "ja")
        #expect(params["sort_by"] == "vote_average.desc")
        #expect(params["vote_count.gte"] != nil, "rating filters need a vote floor")
        let show = DiscoverFilters(kind: .show, genre: nil, yearFrom: 2015, yearTo: nil, minRating: nil, language: nil, sort: "popularity.desc")
        #expect(show.parameters["first_air_date.gte"] == "2015-01-01")
        let data = try? JSONEncoder().encode(DeviceConfig.with(shelf: ShelfConfig(title: "x", query: query)))
        #expect(data != nil)
    }

    @Test func traktListItemsDecode() async throws {
        let body = #"[{"rank":1,"listed_at":"2026-01-01T00:00:00.000Z","type":"movie","movie":{"title":"Dune","year":2021,"ids":{"tmdb":438631}}},{"rank":2,"listed_at":"2026-01-01T00:00:00.000Z","type":"show","show":{"title":"Severance","year":2022,"ids":{"tmdb":95396}}}]"#
        let transport = ScriptedTransport.routes([("/users/me/lists/best/items", body)])
        let trakt = TraktClient(clientID: "C", clientSecret: "S", accessToken: nil, http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in }), transport: transport)
        let items = try await trakt.listItems(user: "me", slug: "best")
        #expect(items.map(\.ref.tmdbID) == [438631, 95396])
    }
}

extension DeviceConfig {
    static func with(shelf: ShelfConfig) -> DeviceConfig {
        var config = DeviceConfig()
        config.shelves = [shelf]
        return config
    }
}

struct SubtitlePrefsTests {
    @Test func appearancePrefsHaveSaneDefaultsAndRoundTrip() throws {
        var prefs = PlayerPrefs()
        #expect(prefs.subtitleSizePercent == 100)
        #expect(prefs.subtitleDelaySeconds == 0)
        prefs.subtitleSizePercent = 150
        prefs.subtitleColor = .yellow
        prefs.subtitleBackground = true
        let decoded = try JSONDecoder().decode(PlayerPrefs.self, from: JSONEncoder().encode(prefs))
        #expect(decoded == prefs)
    }

    @Test func oldConfigWithoutNewFieldsStillDecodes() throws {
        let old = #"{"audioLanguages":["eng"],"subtitleLanguages":["eng"],"subtitlesEnabled":false,"showForcedSubtitles":true,"nextEpisodeLeadSeconds":30,"skipIntro":"button","audioTranscode":"alac"}"#
        let prefs = try JSONDecoder().decode(PlayerPrefs.self, from: Data(old.utf8))
        #expect(prefs.subtitleSizePercent == 100)
    }
}

struct SettingsSearchTests {
    @Test func matchesAllWordsAnywhereInTitleSectionOrKeywords() {
        let entry = SettingsSearch.Entry(title: "Video player", section: "Playback", keywords: ["subtitle size", "dts", "skip intro"])
        #expect(SettingsSearch.matches("subtitle", entry))
        #expect(SettingsSearch.matches("skip intro", entry))
        #expect(SettingsSearch.matches("PLAYER dts", entry))
        #expect(SettingsSearch.matches("playback", entry))
        #expect(!SettingsSearch.matches("jellyfin", entry))
        #expect(SettingsSearch.matches("   ", entry), "empty query matches everything")
    }

    @Test func filterKeepsOrderAndDropsMisses() {
        let entries = [
            SettingsSearch.Entry(title: "Streams", section: "Playback", keywords: ["sort"]),
            SettingsSearch.Entry(title: "Trakt", section: "Account", keywords: ["sync"]),
            SettingsSearch.Entry(title: "Sources", section: "Sources", keywords: ["sort order of sources"]),
        ]
        #expect(SettingsSearch.filter("sort", entries).map(\.title) == ["Streams", "Sources"])
        #expect(SettingsSearch.filter("zzz", entries).isEmpty)
    }
}

struct TorBoxAccountTests {
    @Test func accountStatusReportsPlanAndExpiry() async throws {
        let body = #"{"success":true,"data":{"id":42,"email":"someone@example.com","plan":2,"premium_expires_at":"2026-12-01T00:00:00Z","is_subscribed":true}}"#
        let transport = ScriptedTransport.routes([("/user/me", body)])
        let status = try await TorBoxClient(apiKey: "KEY", transport: transport).account()
        #expect(status.isPremium)
        #expect(status.planName == "Pro")
        #expect(status.premiumExpires == ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
        #expect(!(status.summary(now: ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!)).contains("someone@example.com"), "never show the email")
    }

    @Test func freeOrExpiredAccountsAreNotPremium() async throws {
        let body = #"{"success":true,"data":{"id":1,"plan":0,"premium_expires_at":null,"is_subscribed":false}}"#
        let transport = ScriptedTransport.routes([("/user/me", body)])
        let status = try await TorBoxClient(apiKey: "KEY", transport: transport).account()
        #expect(!status.isPremium)
        #expect(status.summary().contains("Free"))
        let expired = TorBoxAccountStatus(plan: 1, premiumExpires: Date(timeIntervalSince1970: 100), isSubscribed: false)
        #expect(!expired.isPremium(now: Date(timeIntervalSince1970: 200)))
        #expect(expired.summary(now: Date(timeIntervalSince1970: 200)).contains("expired"))
    }

    @Test func badKeyIsReportedAsNeedingCredentials() async {
        let transport = ScriptedTransport { _ in .init(status: 403, body: #"{"success":false,"error":"BAD_TOKEN","detail":"bad"}"#) }
        await #expect(throws: (any Error).self) { _ = try await TorBoxClient(apiKey: "BAD", transport: transport).account() }
    }
}

struct ITunesPreviewTests {
    static let movies = """
    {"resultCount":3,"results":[
      {"trackName":"The Matrix Reloaded","releaseDate":"2003-05-15T07:00:00Z","previewUrl":"https://video.example.com/reloaded.m4v"},
      {"trackName":"The Matrix","releaseDate":"1999-03-31T08:00:00Z","previewUrl":"https://video.example.com/matrix.m4v"},
      {"trackName":"The Matrix","releaseDate":"2021-12-01T08:00:00Z","previewUrl":"https://video.example.com/matrix-doc.m4v"}]}
    """
    static let shows = """
    {"resultCount":3,"results":[
      {"collectionName":"Breaking Bad, Season 2","previewUrl":"https://video.example.com/bb2.m4v"},
      {"collectionName":"Breaking Bad, Season 1","previewUrl":"https://video.example.com/bb1.m4v"},
      {"collectionName":"Better Call Saul, Season 1","previewUrl":"https://video.example.com/bcs.m4v"}]}
    """

    func client(_ body: String) -> (ITunesPreviewClient, ScriptedTransport) {
        let transport = ScriptedTransport { _ in .init(body: body) }
        return (ITunesPreviewClient(http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in })), transport)
    }

    @Test func moviePreviewMatchesTitleAndYear() async throws {
        let (client, transport) = client(Self.movies)
        let url = try await client.previewURL(title: "The Matrix", year: 1999, kind: .movie)
        #expect(url?.lastPathComponent == "matrix.m4v")
        let request = try #require(transport.requests.first?.url)
        #expect(request.host() == "itunes.apple.com")
        #expect(request.query?.contains("entity=movie") == true)
        #expect(request.query?.contains("term=The") == true)
    }

    @Test func noMatchingYearMeansNoPreviewRatherThanTheWrongFilm() async throws {
        let (client, _) = client(Self.movies)
        #expect(try await client.previewURL(title: "The Matrix", year: 2010, kind: .movie) == nil)
        #expect(try await client.previewURL(title: "Something Else", year: 1999, kind: .movie) == nil)
    }

    @Test func showPreviewPicksTheEarliestSeasonOfThatShow() async throws {
        let (client, _) = client(Self.shows)
        let url = try await client.previewURL(title: "Breaking Bad", year: 2008, kind: .show)
        #expect(url?.lastPathComponent == "bb1.m4v")
    }

    @Test func punctuationAndCaseDoNotBreakMatching() {
        #expect(ITunesPreviewClient.normalize("Spider-Man: No Way Home!") == ITunesPreviewClient.normalize("spider man no way home"))
        #expect(ITunesPreviewClient.normalize("  The   Matrix ") == "the matrix")
    }
}

struct ExternalListTests {
    @Test func mdblistReadsTMDBIDsAndKinds() async throws {
        let transport = ScriptedTransport.routes([("mdblist.com/lists/u/best/json", #"[{"id":603,"title":"The Matrix","mediatype":"movie","release_year":1999},{"id":1396,"title":"Breaking Bad","mediatype":"show","release_year":2008}]"#)])
        let client = ExternalListClient(http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in }))
        let entries = try await client.mdblist(path: "u/best")
        #expect(entries.map(\.tmdbID) == [603, 1396])
        #expect(entries.map(\.kind) == [.movie, .show])
    }

    @Test func letterboxdParsesTitleAndYear() {
        let html = #"<div data-item-name="Harakiri (1962)" data-item-slug="harakiri"></div><div data-item-name="Tom &amp; Jerry (2021)"></div><div data-item-name="Harakiri (1962)"></div><div data-item-name="No Year"></div>"#
        let entries = ExternalListClient.parseLetterboxd(html, limit: 10)
        #expect(entries.map(\.title) == ["Harakiri", "Tom & Jerry", "No Year"])
        #expect(entries.map(\.year) == [1962, 2021, nil])
    }

    @Test func letterboxdURLUsesListPath() async throws {
        let transport = ScriptedTransport { _ in .init(body: #"<div data-item-name="Heat (1995)"></div>"#) }
        let client = ExternalListClient(http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in }))
        let entries = try await client.letterboxd(path: "dave/official-top-250")
        #expect(entries.first?.title == "Heat")
        #expect(transport.requests.first?.url?.absoluteString == "https://letterboxd.com/dave/list/official-top-250/")
    }

    @Test func customListsSurviveConfigRoundTripAndOldConfigsLoad() throws {
        var config = DeviceConfig()
        config.customLists = [CustomList(name: "Weekend", titleKeys: ["movie:603"])]
        config.shelves = [ShelfConfig(title: "Weekend", query: .customList(config.customLists[0].id))]
        let back = try JSONDecoder().decode(DeviceConfig.self, from: JSONEncoder().encode(config))
        #expect(back.customLists.first?.titleKeys == ["movie:603"])
        let old = try JSONDecoder().decode(DeviceConfig.self, from: Data(#"{"version":1}"#.utf8))
        #expect(old.customLists.isEmpty)
    }
}

struct UpcomingReleaseTests {
    @Test func showsAndMoviesReportFutureDatesOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)       // 2027-01-15
        #expect(TMDBClient.upcoming(isMovie: true, releaseDate: "2027-03-01", next: nil, now: now)?.label == "Release")
        #expect(TMDBClient.upcoming(isMovie: true, releaseDate: "2020-03-01", next: nil, now: now) == nil)
        #expect(TMDBClient.upcoming(isMovie: false, releaseDate: nil, next: ("2027-02-01", 2, 5), now: now)?.label == "S2 E5")
        #expect(TMDBClient.upcoming(isMovie: false, releaseDate: nil, next: nil, now: now) == nil)
    }
}
