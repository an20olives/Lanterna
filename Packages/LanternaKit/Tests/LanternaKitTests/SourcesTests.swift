import Foundation
import Testing
@testable import LanternaKit

struct SourcesTests {
    static let manifest = URL(string: "https://aio.example.com/stremio/UUID/CFG/manifest.json")!
    static let manifestBody = """
    {"id":"aio","name":"AIOStreams","version":"2.1.0","resources":["stream","catalog","meta","subtitles"],"types":["movie","series"],
     "catalogs":[{"type":"movie","id":"trending","name":"Trending"},{"type":"series","id":"new","name":"New Shows"}]}
    """
    static let streamBody = """
    {"streams":[
      {"name":"🔥4K UHD","description":"🎬 Toy Story 4 (2019)\\n🎥 BluRay REMUX 📺 HDR10 🎞️ HEVC\\n🎧 DTS-HD MA 🔊 5.1\\n📦 30 GB\\n⚡Ready (TB)",
       "url":"https://aio.example.com/play/abc","behaviorHints":{"filename":"Toy.Story.4.2019.2160p.REMUX.mkv","videoSize":32000000000}},
      {"name":"1080p","description":"WEB-DL H.264 ⏳ uncached","url":"https://aio.example.com/play/def","behaviorHints":{"videoSize":4000000000}}
    ]}
    """

    func source(_ table: [(match: String, body: String)]) -> (AIOStreamsSource, ScriptedTransport) {
        let transport = ScriptedTransport.routes(table)
        let client = AIOStreamsClient(manifestURL: Self.manifest, transport: transport)!
        return (AIOStreamsSource(id: SourceID(), client: client), transport)
    }

    @Test func streamsBecomeCandidatesWithParsedFormat() async throws {
        let (source, transport) = source([("/stream/movie/tt1979376.json", Self.streamBody)])
        let candidates = try await source.streams(for: StreamRequest(title: .movie(tmdbID: 301528, imdbID: "tt1979376")))
        #expect(candidates.count == 2)
        let first = candidates[0]
        #expect(first.claimed.resolution == .r2160)
        #expect(first.claimed.hdr == [.hdr10])
        #expect(first.isCached == true)
        #expect(first.sizeBytes == 32_000_000_000)
        #expect(candidates[1].isCached == false)
        #expect(first.id != candidates[1].id)
        #expect(!first.id.contains("abc"))
        #expect(transport.requests.count == 1)
        if case .url(let url) = first.locatorHint { #expect(url.lastPathComponent == "abc") } else { Issue.record("wrong hint") }
    }

    @Test func streamsNeedAnIMDbID() async throws {
        let (source, _) = source([])
        await #expect(throws: SourceError.notFound) { try await source.streams(for: StreamRequest(title: .movie(tmdbID: 1, imdbID: nil))) }
    }

    @Test func episodeUsesSeasonEpisodeID() async throws {
        let (source, transport) = source([("/stream/series/tt0944947:1:2.json", Self.streamBody)])
        _ = try await source.streams(for: StreamRequest(title: .episode(showTMDBID: 1399, imdbID: "tt0944947", season: 1, episode: 2)))
        #expect(transport.requests.first?.url?.path.hasSuffix("/stream/series/tt0944947:1:2.json") == true)
    }

    @Test func catalogsComeFromTheManifest() async throws {
        let (source, _) = source([("manifest.json", Self.manifestBody)])
        let catalogs = try await source.catalogs()
        #expect(catalogs.map(\.title) == ["Trending", "New Shows"])
        #expect(catalogs[1].kind == .show)
        #expect(await source.health() == .ok)
    }

    @Test func catalogPageMapsMetasWithUnresolvedTMDBID() async throws {
        let body = #"{"metas":[{"id":"tt0133093","type":"movie","name":"The Matrix","poster":"https://img/p.jpg","releaseInfo":"1999","description":"A hacker."},{"id":"kitsu:1","type":"movie","name":"Skip me"}]}"#
        let (source, transport) = source([("/catalog/movie/trending", body)])
        let page = try await source.catalogPage(CatalogDescriptor(id: "movie/trending", title: "Trending", kind: .movie), cursor: PageCursor("20"))
        #expect(page.items.count == 1)
        #expect(page.items[0].ref.imdbID == "tt0133093")
        #expect(page.items[0].ref.tmdbID == 0)
        #expect(page.items[0].year == 1999)
        #expect(transport.requests.first?.url?.path.contains("skip=20") == true)
    }

    @Test func subtitlesDecode() async throws {
        let body = #"{"subtitles":[{"id":"1","url":"https://subs/en.srt","lang":"eng"},{"id":"2","url":"https://subs/es.srt","lang":"spa"}]}"#
        let (source, _) = source([("/subtitles/movie/tt1979376", body)])
        let subs = try await source.subtitles(for: StreamRequest(title: .movie(tmdbID: 1, imdbID: "tt1979376")))
        #expect(subs.map(\.language) == ["eng", "spa"])
    }

    @Test func resolveReturnsTheURLAndOtherHintsAreRejected() async throws {
        let (source, _) = source([])
        let url = URL(string: "https://aio.example.com/play/abc")!
        #expect(try await source.resolve(.url(url)).url == url)
        await #expect(throws: SourceError.unsupported) { try await source.resolve(.jellyfin(itemID: "1", mediaSourceID: nil)) }
    }

    // MARK: Release names and matching

    static let releaseCases: [(String, String, Int?, Int?, Int?)] = [
        ("Toy.Story.4.2019.2160p.UHD.BluRay.REMUX.HDR.HEVC.DTS-HD.MA.5.1-EFPG.mkv", "Toy Story 4", 2019, nil, nil),
        ("The.Matrix.1999.1080p.BluRay.x264-GRP.mkv", "The Matrix", 1999, nil, nil),
        ("Game.of.Thrones.S01E02.1080p.WEB-DL.DDP5.1.H.264-NTb.mkv", "Game of Thrones", nil, 1, 2),
        ("some show 2x05 720p.mkv", "some show", nil, 2, 5),
        ("2012.2009.1080p.BluRay.mkv", "2012", 2009, nil, nil),
    ]

    @Test(arguments: releaseCases)
    func parsesReleaseNames(name: String, title: String, year: Int?, season: Int?, episode: Int?) {
        let parsed = ReleaseNameParser.parse(name)
        #expect(parsed.title == title)
        #expect(parsed.year == year)
        #expect(parsed.season == season)
        #expect(parsed.episode == episode)
    }

    @Test func matcherIsConservative() async {
        let hit = TitleSummary(ref: .movie(tmdbID: 301528, imdbID: nil), title: "Toy Story 4", year: 2019)
        let other = TitleSummary(ref: .movie(tmdbID: 9, imdbID: nil), title: "Toy Story 4", year: 2019)
        let matcher = LibraryMatcher(search: { query, _ in
            switch query {
            case "Toy Story 4": [hit]
            case "Twins": [hit, other]
            default: []
            }
        })
        let ok = await matcher.match(ReleaseNameParser.parse("Toy.Story.4.2019.2160p.mkv"))
        #expect(ok == .matched(.movie(tmdbID: 301528, imdbID: nil)))
        #expect(await matcher.match(ReleaseNameParser.parse("Twins.2019.1080p.mkv")) == .ambiguous)
        #expect(await matcher.match(ReleaseNameParser.parse("Nothing.Here.2001.mkv")) == .unmatched)
    }

    @Test func torboxLibraryMapsReadyItemsAndResolves() async throws {
        let list = """
        {"success":true,"data":[{"id":11,"name":"Toy.Story.4.2019.2160p","size":32000000000,"download_state":"cached","download_finished":true,"cached":true,
          "files":[{"id":0,"name":"Toy.Story.4.2019.2160p/Toy.Story.4.2019.2160p.mkv","short_name":"Toy.Story.4.2019.2160p.mkv","size":31000000000,"mimetype":"video/x-matroska"},
                   {"id":1,"name":"sample.nfo","short_name":"sample.nfo","size":10,"mimetype":"text/plain"}]},
         {"id":12,"name":"Still.Downloading","size":1,"download_state":"downloading","download_finished":false,"cached":false,"files":[]}]}
        """
        let transport = ScriptedTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("requestdl") { return .init(body: #"{"success":true,"data":"https://cdn.example.com/dl/xyz"}"#) }
            return url.contains("/torrents/mylist") ? .init(body: list) : .init(body: #"{"success":true,"data":[]}"#)
        }
        let client = TorBoxClient(apiKey: "KEY", transport: transport)
        let source = TorBoxSource(id: SourceID(), client: client)
        let page = try await source.libraryPage(cursor: nil)
        #expect(page.items.count == 2)
        let ready = try #require(page.items.first { $0.isReady })
        #expect(ready.files.count == 1)
        #expect(ready.title == "Toy.Story.4.2019.2160p")
        #expect(page.items.first { !$0.isReady }?.statusText == "downloading")
        let locator = try await source.resolve(ready.files[0].locatorHint)
        #expect(locator.url.host == "cdn.example.com")
    }
}
