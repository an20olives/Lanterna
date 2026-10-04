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
