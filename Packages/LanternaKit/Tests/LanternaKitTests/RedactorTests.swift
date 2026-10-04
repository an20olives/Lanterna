import Foundation
import Testing
@testable import LanternaKit

struct RedactorTests {
    @Test func stripsQueryStringsBecauseTorBoxPutsTheKeyThere() {
        let url = URL(string: "https://api.torbox.app/v1/api/torrents/requestdl?token=SECRET&torrent_id=1&file_id=2")!
        #expect(Redactor.url(url) == "https://api.torbox.app/v1/api/torrents/requestdl?<redacted>")
    }

    @Test func hidesAIOStreamsConfigPath() {
        let url = URL(string: "https://aiostreams.example.com/stremio/abc/eyJlbmNyeXB0ZWQiOiJ4In0/manifest.json")!
        #expect(Redactor.url(url) == "https://aiostreams.example.com/<redacted>")
    }

    @Test func cdnPathsAreReducedToHostAndFileExtension() {
        let url = URL(string: "https://store-031.weur.tb-cdn.st/zip/abcdef0123456789/Movie.2023.2160p.mkv?token=x")!
        #expect(Redactor.url(url) == "https://store-031.weur.tb-cdn.st/<redacted>.mkv")
    }

    @Test func localhostSessionURLsKeepRouteButHideToken() {
        let url = URL(string: "http://127.0.0.1:51234/0f3a9c2e7b1d4a6f8e5c0b9a7d3e1f2c/v/12.m4s")!
        #expect(Redactor.url(url) == "http://127.0.0.1:51234/<token>/v/12.m4s")
    }

    @Test func scrubsKnownSecretsInsideFreeText() {
        let secrets = ["SECRET-KEY-123"]
        #expect(Redactor.text("auth failed for SECRET-KEY-123 at host", secrets: secrets)
                == "auth failed for <redacted> at host")
    }

    @Test func scrubsURLsInsideFreeText() {
        let line = "GET https://api.torbox.app/v1/api/torrents/mylist?bypass_cache=true failed"
        #expect(Redactor.text(line) == "GET https://api.torbox.app/v1/api/torrents/mylist?<redacted> failed")
    }
}
