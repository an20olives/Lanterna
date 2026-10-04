import Foundation
import Testing
@testable import LanternaKit

struct JellyfinTests {
    static let base = URL(string: "https://pi.tailnet.ts.net")!
    static let device = JellyfinDevice(deviceID: "DEV-1", deviceName: "Apple TV", version: "0.1")

    static let movies = """
    {"Items":[{"Id":"abc","Name":"The Matrix","Type":"Movie","ProductionYear":1999,"ProviderIds":{"Tmdb":"603","Imdb":"tt0133093"},
      "DateCreated":"2025-01-02T03:04:05.0000000Z","RunTimeTicks":81600000000,
      "MediaSources":[{"Id":"ms1","Size":30000000000,"Container":"mkv","Name":"The Matrix 2160p",
        "MediaStreams":[{"Type":"Video","Codec":"hevc","Width":3840,"Height":2160,"VideoRangeType":"DOVIWithHDR10"},
                        {"Type":"Audio","Codec":"truehd","DisplayTitle":"English TrueHD Atmos 7.1","Channels":8}]}]},
     {"Id":"def","Name":"No IDs","Type":"Movie","ProductionYear":2000,"ProviderIds":{}}],"TotalRecordCount":2}
    """

    func client(_ table: [(match: String, body: String)]) -> (JellyfinClient, ScriptedTransport) {
        let transport = ScriptedTransport.routes(table)
        return (JellyfinClient(baseURL: Self.base, device: Self.device, token: "TOK", userID: "U1",
                               http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in })), transport)
    }

    @Test func authorizationHeaderCarriesDeviceAndToken() {
        let (client, _) = client([])
        let header = client.request("/Items").value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(header.hasPrefix("MediaBrowser "))
        #expect(header.contains("DeviceId=\"DEV-1\""))
        #expect(header.contains("Token=\"TOK\""))
        #expect(!(client.request("/Items").url?.absoluteString.contains("TOK") ?? true))
    }

    @Test func libraryMatchesByProviderIDsOnly() async throws {
        let (client, _) = client([("/Items", Self.movies)])
        let source = JellyfinSource(id: SourceID(), displayName: "Home", client: client)
        let page = try await source.libraryPage(cursor: nil)
        #expect(page.items.count == 2)
        #expect(page.items[0].matched == .movie(tmdbID: 603, imdbID: "tt0133093"))
        #expect(page.items[1].matched == nil)
    }

    @Test func movieStreamsComeFromMediaSources() async throws {
        let (client, transport) = client([("anyProviderIdEquals", Self.movies)])
        let source = JellyfinSource(id: SourceID(), displayName: "Home", client: client)
        let streams = try await source.streams(for: StreamRequest(title: .movie(tmdbID: 603, imdbID: "tt0133093")))
        #expect(streams.count == 1)
        let stream = streams[0]
        #expect(stream.claimed.resolution == .r2160)
        #expect(stream.claimed.hdr.contains(.dolbyVision))
        #expect(stream.claimed.hasAtmos)
        #expect(stream.sourceKind == .jellyfin)
        #expect(stream.isCached == true)
        #expect(transport.requests.first?.url?.query?.contains("tmdb.603") == true)
        let locator = try await source.resolve(stream.locatorHint)
        #expect(locator.url.path == "/Videos/abc/stream")
        #expect(locator.url.query?.contains("static=true") == true)
        #expect(locator.url.query?.contains("mediaSourceId=ms1") == true)
        #expect(locator.headers["Authorization"]?.contains("Token=\"TOK\"") == true)
    }

    @Test func playbackReportsUseTicks() async throws {
        let (client, transport) = client([("/Sessions/Playing", "")])
        let source = JellyfinSource(id: SourceID(), displayName: "Home", client: client)
        try await source.reportPlayback(PlaybackReport(title: .movie(tmdbID: 603, imdbID: nil), phase: .stop, positionSeconds: 12.5, durationSeconds: 100, sessionID: "S"),
                                        itemID: "abc", mediaSourceID: "ms1")
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/Sessions/Playing/Stopped")
        let body = try #require(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["PositionTicks"] as? Int == 125_000_000)
        #expect(body["ItemId"] as? String == "abc")
    }

    @Test func quickConnectRoundTrip() async throws {
        let transport = ScriptedTransport.routes([
            ("/QuickConnect/Initiate", #"{"Code":"123456","Secret":"SEC","Authenticated":false}"#),
            ("/QuickConnect/Connect", #"{"Code":"123456","Secret":"SEC","Authenticated":true}"#),
            ("/Users/AuthenticateWithQuickConnect", #"{"AccessToken":"NEWTOK","User":{"Id":"U9"},"ServerId":"srv"}"#),
        ])
        let client = JellyfinClient(baseURL: Self.base, device: Self.device, token: nil, userID: nil,
                                    http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in }))
        let session = try await client.quickConnectInitiate()
        #expect(session.code == "123456")
        #expect(try await client.quickConnectAuthenticated(secret: session.secret))
        let auth = try await client.authenticateWithQuickConnect(secret: session.secret)
        #expect(auth.accessToken == "NEWTOK")
        #expect(auth.userID == "U9")
    }
}

struct TraktTests {
    func client(_ table: [(match: String, status: Int, body: String)]) -> (TraktClient, ScriptedTransport) {
        let transport = ScriptedTransport { request in
            let url = request.url?.absoluteString ?? ""
            if let hit = table.first(where: { url.contains($0.match) }) { return .init(status: hit.status, body: hit.body) }
            return .init(status: 404, body: "{}")
        }
        return (TraktClient(clientID: "CID", clientSecret: "CSEC", accessToken: "ACC", http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in }), transport: transport), transport)
    }

    @Test func headersFollowTraktRules() async throws {
        let (client, transport) = client([("/sync/last_activities", 200, #"{"all":"2026-01-01T00:00:00.000Z"}"#)])
        _ = try await client.lastActivities()
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "trakt-api-version") == "2")
        #expect(request.value(forHTTPHeaderField: "trakt-api-key") == "CID")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ACC")
    }

    @Test func deviceCodeFlow() async throws {
        let (client, _) = client([("/oauth/device/code", 200, #"{"device_code":"DC","user_code":"ABCD1234","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}"#)])
        let code = try await client.deviceCode()
        #expect(code.userCode == "ABCD1234")
        #expect(code.interval == 5)
    }

    @Test(arguments: [
        (200, TraktPoll.signedIn(TraktTokens(accessToken: "A", refreshToken: "R", expiresAt: Date(timeIntervalSince1970: 1_000_000 + 7_776_000)))),
        (400, TraktPoll.pending), (429, TraktPoll.slowDown), (410, TraktPoll.expired), (418, TraktPoll.denied), (404, TraktPoll.invalid), (409, TraktPoll.alreadyUsed),
    ])
    func pollingMapsStatuses(status: Int, expected: TraktPoll) async throws {
        let body = #"{"access_token":"A","refresh_token":"R","expires_in":7776000,"created_at":1000000}"#
        let (client, _) = client([("/oauth/device/token", status, status == 200 ? body : "{}")])
        #expect(try await client.pollDeviceToken(deviceCode: "DC") == expected)
    }

    @Test func refreshReplacesBothTokens() async throws {
        let body = #"{"access_token":"A2","refresh_token":"R2","expires_in":7776000,"created_at":2000000}"#
        let (client, transport) = client([("/oauth/token", 200, body)])
        let tokens = try await client.refresh(refreshToken: "R1")
        #expect(tokens.accessToken == "A2")
        #expect(tokens.refreshToken == "R2")
        let sent = try #require(transport.requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(sent["grant_type"] == "refresh_token")
        #expect(sent["refresh_token"] == "R1")
    }

    @Test func playbackProgressDecodesMoviesAndEpisodes() async throws {
        let body = """
        [{"id":1,"progress":42.5,"paused_at":"2026-10-04T12:00:00.000Z","type":"movie","movie":{"title":"The Matrix","year":1999,"ids":{"trakt":1,"tmdb":603,"imdb":"tt0133093"}}},
         {"id":2,"progress":10,"paused_at":"2026-10-04T13:00:00.000Z","type":"episode","episode":{"season":1,"number":2,"title":"Kingsroad","ids":{"tmdb":63}},"show":{"title":"GoT","year":2011,"ids":{"tmdb":1399,"imdb":"tt0944947"}}}]
        """
        let (client, _) = client([("/sync/playback", 200, body)])
        let items = try await client.playback()
        #expect(items.count == 2)
        #expect(items[0].ref == .movie(tmdbID: 603, imdbID: "tt0133093"))
        #expect(items[0].progress == 42.5)
        #expect(items[1].ref == .episode(showTMDBID: 1399, imdbID: "tt0944947", season: 1, episode: 2))
        #expect(items[1].pausedAt > items[0].pausedAt)
    }

    @Test func scrobbleBodyUsesTMDBIDs() async throws {
        let (client, transport) = client([("/scrobble/stop", 200, #"{"id":1,"action":"scrobble"}"#)])
        try await client.scrobble(.stop, title: .episode(showTMDBID: 1399, imdbID: nil, season: 1, episode: 2), progress: 95)
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/scrobble/stop")
        let body = try #require(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["progress"] as? Double == 95)
        let show = body["show"] as? [String: Any]
        #expect((show?["ids"] as? [String: Int])?["tmdb"] == 1399)
        let episode = body["episode"] as? [String: Int]
        #expect(episode?["season"] == 1 && episode?["number"] == 2)
    }

    @Test func scrobbleConflictCountsAsSuccess() async throws {
        let (client, _) = client([("/scrobble/stop", 409, "{}")])
        try await client.scrobble(.stop, title: .movie(tmdbID: 603, imdbID: nil), progress: 95)
    }

    @Test func watchlistDecodes() async throws {
        let body = #"[{"listed_at":"2026-01-01T00:00:00.000Z","type":"movie","movie":{"title":"Dune","year":2021,"ids":{"tmdb":438631,"imdb":"tt1160419"}}},{"listed_at":"2026-01-02T00:00:00.000Z","type":"show","show":{"title":"Severance","year":2022,"ids":{"tmdb":95396}}}]"#
        let (client, _) = client([("/sync/watchlist", 200, body)])
        let items = try await client.watchlist()
        #expect(items.map(\.ref.tmdbID) == [438631, 95396])
        #expect(items[1].ref.kind == .show)
    }
}
