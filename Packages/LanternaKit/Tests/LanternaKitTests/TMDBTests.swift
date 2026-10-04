import Foundation
import Testing
@testable import LanternaKit

/// Shapes follow https://developer.themoviedb.org/reference (hand-written fixtures; verify against live responses).
struct TMDBTests {
    static let trending = """
    {"page":1,"total_pages":3,"results":[
      {"id":603,"media_type":"movie","title":"The Matrix","release_date":"1999-03-30","poster_path":"/m.jpg","backdrop_path":"/mb.jpg","overview":"A hacker.","vote_average":8.2},
      {"id":1399,"media_type":"tv","name":"Game of Thrones","first_air_date":"2011-04-17","poster_path":"/g.jpg","backdrop_path":null,"overview":"Dragons.","vote_average":8.4},
      {"id":287,"media_type":"person","name":"Brad Pitt"}
    ]}
    """
    static let movie = """
    {"id":603,"title":"The Matrix","tagline":"Welcome to the Real World.","runtime":136,"release_date":"1999-03-30",
     "overview":"A hacker.","poster_path":"/m.jpg","backdrop_path":"/mb.jpg","vote_average":8.2,
     "genres":[{"id":28,"name":"Action"},{"id":878,"name":"Science Fiction"}],
     "external_ids":{"imdb_id":"tt0133093"},
     "videos":{"results":[{"key":"abc","name":"Trailer","site":"YouTube","type":"Trailer"},{"key":"zzz","name":"Clip","site":"YouTube","type":"Clip"},{"key":"v1","name":"Vimeo","site":"Vimeo","type":"Trailer"}]},
     "credits":{"cast":[{"id":6384,"name":"Keanu Reeves","character":"Neo","profile_path":"/k.jpg"}]},
     "images":{"logos":[{"file_path":"/fr.png","iso_639_1":"fr"},{"file_path":"/en.png","iso_639_1":"en"}]},
     "release_dates":{"results":[{"iso_3166_1":"GB","release_dates":[{"certification":"15","type":3}]},{"iso_3166_1":"US","release_dates":[{"certification":"","type":1},{"certification":"R","type":3}]}]}}
    """
    static let tv = """
    {"id":1399,"name":"Game of Thrones","tagline":"","episode_run_time":[57],"first_air_date":"2011-04-17","overview":"Dragons.",
     "poster_path":"/g.jpg","backdrop_path":"/gb.jpg","vote_average":8.4,"genres":[{"id":10765,"name":"Sci-Fi & Fantasy"}],
     "external_ids":{"imdb_id":"tt0944947"},
     "seasons":[{"season_number":0,"name":"Specials","episode_count":2,"poster_path":null},{"season_number":1,"name":"Season 1","episode_count":10,"poster_path":"/s1.jpg"}],
     "content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-MA"}]},
     "videos":{"results":[]},"credits":{"cast":[]},"images":{"logos":[]}}
    """
    static let season = """
    {"episodes":[{"season_number":1,"episode_number":1,"name":"Winter Is Coming","overview":"Eddard.","air_date":"2011-04-17","still_path":"/e1.jpg","runtime":62,"vote_average":8.1},
                 {"season_number":1,"episode_number":2,"name":"The Kingsroad","overview":null,"air_date":null,"still_path":null,"runtime":null,"vote_average":7.9}]}
    """
    static let providers = """
    {"results":{"US":{"link":"x","flatrate":[{"provider_id":337,"provider_name":"Disney Plus","logo_path":"/d.jpg"}],"rent":[{"provider_id":2,"provider_name":"Apple TV","logo_path":"/a.jpg"}]},"GB":{"free":[{"provider_id":9,"provider_name":"Freeview","logo_path":null}]}}}
    """

    func client(_ table: [(match: String, body: String)]) -> (TMDBClient, ScriptedTransport) {
        let transport = ScriptedTransport.routes(table)
        return (TMDBClient(readToken: "TOKEN", http: HTTPClient(transport: transport, maxRetries: 0, sleep: { _ in })), transport)
    }

    @Test func trendingMapsMoviesAndShowsAndSkipsPeople() async throws {
        let (client, transport) = client([("/trending/all/week", Self.trending)])
        let page = try await client.trending(window: .week)
        #expect(page.items.map(\.title) == ["The Matrix", "Game of Thrones"])
        #expect(page.items[0].ref == .movie(tmdbID: 603, imdbID: nil))
        #expect(page.items[0].year == 1999)
        #expect(page.items[1].ref.kind == .show)
        #expect(page.next?.value == "2")
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
        #expect(!(request.url?.absoluteString.contains("TOKEN") ?? true))
    }

    @Test func movieDetailPicksTrailersLogoAndCertification() async throws {
        let (client, _) = client([("/movie/603", Self.movie)])
        let detail = try await client.detail(.movie(tmdbID: 603, imdbID: nil), region: "US")
        #expect(detail.summary.ref.imdbID == "tt0133093")
        #expect(detail.runtimeMinutes == 136)
        #expect(detail.certification == "R")
        #expect(detail.genres == ["Action", "Science Fiction"])
        #expect(detail.trailers.map(\.youtubeKey) == ["abc"])
        #expect(detail.logoPath == "/en.png")
        #expect(detail.cast.first?.character == "Neo")
    }

    @Test func tvDetailListsSeasonsAndRating() async throws {
        let (client, _) = client([("/tv/1399", Self.tv)])
        let detail = try await client.detail(.show(tmdbID: 1399, imdbID: nil), region: "US")
        #expect(detail.summary.ref.imdbID == "tt0944947")
        #expect(detail.certification == "TV-MA")
        #expect(detail.runtimeMinutes == 57)
        #expect(detail.seasons.map(\.number) == [0, 1])
    }

    @Test func seasonEpisodesParseDatesAsUTC() async throws {
        let (client, _) = client([("/tv/1399/season/1", Self.season)])
        let episodes = try await client.season(showID: 1399, number: 1)
        #expect(episodes.count == 2)
        #expect(episodes[0].name == "Winter Is Coming")
        #expect(episodes[0].airDate == ISO8601DateFormatter().date(from: "2011-04-17T00:00:00Z"))
        #expect(episodes[1].airDate == nil)
    }

    @Test func watchProvidersAreFilteredByRegion() async throws {
        let (client, _) = client([("/movie/603/watch/providers", Self.providers)])
        let offers = try await client.watchProviders(for: .movie(tmdbID: 603, imdbID: nil), region: "US")
        #expect(Set(offers.map(\.providerID)) == [337, 2])
        #expect(offers.first { $0.providerID == 337 }?.type == .flatrate)
        #expect(try await client.watchProviders(for: .movie(tmdbID: 603, imdbID: nil), region: "FR").isEmpty)
    }

    @Test func searchSplitsKinds() async throws {
        let (client, transport) = client([("/search/multi", Self.trending)])
        let results = try await client.search("matrix")
        #expect(results.titles.count == 2)
        #expect(results.people.map(\.name) == ["Brad Pitt"])
        #expect(transport.requests.first?.url?.query?.contains("query=matrix") == true)
    }

    @Test func findByIMDbResolvesTMDBID() async throws {
        let body = #"{"movie_results":[{"id":603,"title":"The Matrix","release_date":"1999-03-30"}],"tv_results":[]}"#
        let (client, _) = client([("/find/tt0133093", body)])
        let summary = try await client.find(imdbID: "tt0133093")
        #expect(summary?.ref == .movie(tmdbID: 603, imdbID: "tt0133093"))
    }

    @Test func imageURLsUseSizeAndPath() {
        #expect(TMDBImage.url("/m.jpg", .poster)?.absoluteString == "https://image.tmdb.org/t/p/w500/m.jpg")
        #expect(TMDBImage.url(nil, .poster) == nil)
        #expect(TMDBImage.url("/b.jpg", .backdrop)?.absoluteString == "https://image.tmdb.org/t/p/w1280/b.jpg")
    }

    @Test func tmdbSourceExposesCatalogsAndDetail() async throws {
        let (client, _) = client([("/trending/movie/week", Self.trending), ("/movie/603", Self.movie)])
        let source = TMDBSource(id: SourceID(), client: client, region: "US")
        let catalogs = try await source.catalogs()
        #expect(catalogs.contains { $0.id == "trending-movie" })
        let page = try await source.catalogPage(try #require(catalogs.first { $0.id == "trending-movie" }), cursor: nil)
        #expect(!page.items.isEmpty)
        let detail = try await source.metadata(for: .movie(tmdbID: 603, imdbID: nil))
        #expect(detail.certification == "R")
        await #expect(throws: SourceError.unsupported) { try await source.streams(for: StreamRequest(title: .movie(tmdbID: 1, imdbID: nil))) }
    }
}
