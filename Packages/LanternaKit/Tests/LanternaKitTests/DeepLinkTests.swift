import Foundation
import Testing
@testable import LanternaKit

struct DeepLinkTests {
    static let json = """
    [{"providerID":337,"name":"Disney Plus","scheme":"disneyplus","level":"app-only","template":null,"verifiedOn":null,"notes":""},
     {"providerID":8,"name":"Netflix","scheme":"nflx","level":"search","template":"nflx://www.netflix.com/search?q={title}","verifiedOn":null,"notes":""},
     {"providerID":350,"name":"Apple TV Plus","scheme":"videos","level":"title","template":"videos://tv.apple.com/show/{tmdb}?season={season}&episode={episode}","verifiedOn":"2026-10-04","notes":""}]
    """

    @Test func appOnlyOpensTheScheme() throws {
        let archive = try DeepLinkArchive.decode(Data(Self.json.utf8))
        let link = archive.link(providerID: 337, title: "Toy Story 4", ref: .movie(tmdbID: 301528, imdbID: nil))
        #expect(link?.url.absoluteString == "disneyplus://")
        #expect(link?.level == .appOnly)
    }

    @Test func templatesFillTitleAndEpisodeAndEscape() throws {
        let archive = try DeepLinkArchive.decode(Data(Self.json.utf8))
        let search = archive.link(providerID: 8, title: "Toy Story & Co", ref: .movie(tmdbID: 1, imdbID: nil))
        #expect(search?.url.absoluteString == "nflx://www.netflix.com/search?q=Toy%20Story%20%26%20Co")
        let episode = archive.link(providerID: 350, title: "Show", ref: .episode(showTMDBID: 77, imdbID: nil, season: 2, episode: 5))
        #expect(episode?.url.absoluteString == "videos://tv.apple.com/show/77?season=2&episode=5")
        #expect(episode?.level == .title)
    }

    @Test func unknownProvidersHaveNoLink() throws {
        let archive = try DeepLinkArchive.decode(Data(Self.json.utf8))
        #expect(archive.link(providerID: 9999, title: "x", ref: .movie(tmdbID: 1, imdbID: nil)) == nil)
    }

    @Test func schemesListMatchesArchive() throws {
        let archive = try DeepLinkArchive.decode(Data(Self.json.utf8))
        #expect(Set(archive.schemes) == ["disneyplus", "nflx", "videos"])
    }
}
