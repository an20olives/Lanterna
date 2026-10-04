import Foundation
import Testing
@testable import LanternaKit

/// Shapes follow https://api-docs.torbox.app (Postman collection, read 2026-10-04).
struct TorBoxClientTests {
    let client = TorBoxClient(apiKey: "KEY", transport: StubTransport())

    @Test func listRequestUsesBearerAuthAndNoKeyInURL() throws {
        let request = client.listRequest(.torrents)
        #expect(request.url?.absoluteString == "https://api.torbox.app/v1/api/torrents/mylist")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer KEY")
        #expect(!(request.url?.absoluteString.contains("KEY") ?? true))
    }

    @Test(arguments: [
        (TorBoxKind.torrents, "torrents/requestdl", "torrent_id"),
        (.usenet, "usenet/requestdl", "usenet_id"),
        (.webDownloads, "webdl/requestdl", "web_id"),
    ])
    func downloadLinkRequestPutsKeyInTokenParameter(kind: TorBoxKind, path: String, idName: String) throws {
        let request = client.downloadLinkRequest(kind: kind, itemID: 11, fileID: 3)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(components.path == "/v1/api/\(path)")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["token"] == "KEY")
        #expect(query[idName] == "11")
        #expect(query["file_id"] == "3")
        #expect(query["redirect"] == nil)
    }

    @Test func decodesTorrentListWithFiles() throws {
        let json = """
        {"success": true, "error": null, "detail": "ok", "data": [
          {"id": 11, "hash": "h", "name": "Some.Movie.2023.2160p.DV.mkv", "size": 50000000000,
           "download_state": "cached", "download_finished": true, "cached": true,
           "created_at": "2026-03-08T21:21:28Z",
           "files": [
             {"id": 0, "name": "Some.Movie.2023.2160p.DV/Some.Movie.2023.2160p.DV.mkv", "short_name": "Some.Movie.2023.2160p.DV.mkv",
              "size": 49000000000, "mimetype": "video/x-matroska"},
             {"id": 1, "name": "Some.Movie.2023.2160p.DV/sample.nfo", "short_name": "sample.nfo",
              "size": 1000, "mimetype": "text/plain"}
           ]}
        ]}
        """
        let items = try TorBoxClient.decodeList(Data(json.utf8), kind: .torrents)
        #expect(items.count == 1)
        #expect(items[0].id == 11)
        #expect(items[0].isReady)
        #expect(items[0].videoFiles.map(\.id) == [0])
        #expect(items[0].videoFiles[0].shortName == "Some.Movie.2023.2160p.DV.mkv")
    }

    @Test func decodesDownloadLink() throws {
        let json = #"{"success": true, "error": null, "detail": "ok", "data": "https://cdn.example/f.mkv?t=1"}"#
        #expect(try TorBoxClient.decodeLink(Data(json.utf8)) == URL(string: "https://cdn.example/f.mkv?t=1"))
    }

    @Test func apiErrorSurfacesDetailNotTheKey() throws {
        let json = #"{"success": false, "error": "AUTH_ERROR", "detail": "Invalid token.", "data": null}"#
        #expect(throws: TorBoxError.api(code: "AUTH_ERROR", detail: "Invalid token.")) {
            try TorBoxClient.decodeLink(Data(json.utf8))
        }
    }
}

struct StubTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
