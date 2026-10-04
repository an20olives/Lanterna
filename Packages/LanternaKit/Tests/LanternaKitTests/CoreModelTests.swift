import Foundation
import Testing
@testable import LanternaKit

struct CoreModelTests {
    @Test func titleKeysAndStremioIDs() {
        let movie = TitleRef.movie(tmdbID: 603, imdbID: "tt0133093")
        #expect(movie.key == "movie:603")
        #expect(movie.stremioType == "movie")
        #expect(movie.stremioID == "tt0133093")
        let episode = TitleRef.episode(showTMDBID: 1399, imdbID: "tt0944947", season: 1, episode: 2)
        #expect(episode.key == "episode:1399:1:2")
        #expect(episode.stremioType == "series")
        #expect(episode.stremioID == "tt0944947:1:2")
        #expect(TitleRef.show(tmdbID: 1399, imdbID: nil).stremioID == nil)
    }

    @Test func parsesAIOStreamsDescription() {
        let description = """
        🎬 The Matrix (1999) \n🎥 BluRay REMUX 📺 DV | HDR10 🎞️ HEVC ⏱️ 2h:16m:18s \n🎧 TrueHD | DTS-HD MA | DD | Atmos 🔊 7.1 | 5.1 | 2.0 🗣️ 🇬🇧 \n📦 73.4 GB / 147 GB 📊 71.4 Mbps \n⚡Ready (TB) 🔍ElfCache
        """
        let format = ClaimedFormat.parse(name: "🔥4K UHD", description: description, filename: "The.Matrix.1999.2160p.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.Atmos-GRP.mkv")
        #expect(format.resolution == .r2160)
        #expect(format.hdr.contains(.dolbyVision))
        #expect(format.hdr.contains(.hdr10))
        #expect(format.videoCodec == "HEVC")
        #expect(format.hasAtmos)
        #expect(format.audioCodecs.contains("TrueHD"))
        #expect(format.audioCodecs.contains("DTS-HD MA"))
        #expect(format.source == "REMUX")
        #expect(format.isCachedClaim == true)
    }

    @Test func parsesPlainFilenames() {
        let format = ClaimedFormat.parse(name: nil, description: nil, filename: "Show.S01E02.1080p.WEB-DL.DDP5.1.H.264-NTb.mkv")
        #expect(format.resolution == .r1080)
        #expect(format.hdr.isEmpty)
        #expect(format.videoCodec == "H.264")
        #expect(format.audioCodecs.contains("EAC3"))
        #expect(format.source == "WEB-DL")
        #expect(format.isCachedClaim == nil)
        #expect(ClaimedFormat.parse(name: "720p", description: nil, filename: nil).resolution == .r720)
    }

    @Test func deviceConfigCapsShelvesAndRoundTrips() throws {
        var config = DeviceConfig()
        config.shelves = (0..<25).map { ShelfConfig(title: "S\($0)", query: .preset("trending")) }
        #expect(config.validated().shelves.count == DeviceConfig.maxShelves)
        let data = try JSONEncoder().encode(config.validated())
        #expect(data.count < 64 * 1024)
        let decoded = try JSONDecoder().decode(DeviceConfig.self, from: data)
        #expect(decoded.version == DeviceConfig.currentVersion)
    }

    @Test func deviceConfigStoreUsesGivenDefaults() throws {
        let defaults = UserDefaults(suiteName: "lanterna.test.\(UUID().uuidString)")!
        let store = DeviceConfigStore(defaults: defaults)
        #expect(store.load() == DeviceConfig())
        var config = DeviceConfig()
        config.watchRegion = "GB"
        config.subscribedServices = [SubscribedService(providerID: 337, name: "Disney Plus")]
        store.save(config)
        #expect(store.load().watchRegion == "GB")
        #expect(store.load().subscribedServices.first?.providerID == 337)
    }

    @Test func streamCandidateDescriptionHidesLocator() {
        let candidate = StreamCandidate(sourceID: SourceID(), title: .movie(tmdbID: 1, imdbID: "tt1"), displayName: "Movie 2160p",
                                        locatorHint: .url(URL(string: "https://cdn.example.com/secret-token")!))
        #expect(!"\(candidate)".contains("secret-token"))
        #expect(!String(reflecting: candidate).contains("secret-token"))
    }
}
