import Foundation
import LanternaKit

/// Debug aid: serves a folder of test files over HTTP as streams for any title. Enabled with
/// `-dev-media-url http://127.0.0.1:8000`. Never configured in a normal run.
struct DevMediaSource: MediaSource {
    let id: SourceID
    let kind = SourceKind.torbox
    let displayName = "Dev media"
    let capabilities: SourceCapabilities = [.streams]
    let base: URL

    init(base: URL, id: SourceID) {
        self.base = base
        self.id = id
    }

    static func fromLaunchArguments(id: SourceID) -> DevMediaSource? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-dev-media-url"), index + 1 < args.count, let url = URL(string: args[index + 1]) else { return nil }
        return DevMediaSource(base: url, id: id)
    }

    func streams(for request: StreamRequest) async throws -> [StreamCandidate] {
        let files: [(name: String, size: Int64, label: String)] = [
            ("t1-h264-aac.mp4", 46_000_000, "Dev 1080p H.264 AAC MP4"),
            ("t2-hevc-ac3.mkv", 54_000_000, "Dev 1080p HEVC AC3 MKV"),
            ("t3-h264-flac.mkv", 46_000_000, "Dev 1080p H.264 FLAC MKV"),
        ]
        return files.map { file in
            StreamCandidate(id: "dev:\(file.name)", sourceID: id, sourceKind: .torbox, title: request.title, displayName: file.label,
                            sizeBytes: file.size, claimed: ClaimedFormat.parse(name: nil, description: file.label, filename: file.name),
                            isCached: true, locatorHint: .url(base.appending(path: file.name)))
        }
    }

    func resolve(_ hint: LocatorHint) async throws -> PlaybackLocator {
        guard case .url(let url) = hint else { throw SourceError.unsupported }
        return PlaybackLocator(url: url)
    }
}
