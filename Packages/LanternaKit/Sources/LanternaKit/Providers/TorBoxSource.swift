import Foundation

/// The owner's own TorBox library. The API key is held in memory by `TorBoxClient`.
public struct TorBoxSource: MediaSource {
    public let id: SourceID
    public let kind = SourceKind.torbox
    public let displayName = "TorBox"
    public let capabilities: SourceCapabilities = [.library, .streams]
    let client: TorBoxClient

    public init(id: SourceID, client: TorBoxClient) {
        self.id = id
        self.client = client
    }

    public func libraryPage(cursor: PageCursor?) async throws -> Page<LibraryItem> {
        var items: [LibraryItem] = []
        for kind in TorBoxKind.allCases {
            do {
                items += try await client.list(kind).map { item in
                    LibraryItem(id: "\(kind.rawValue):\(item.id)", sourceID: id, title: item.name, sizeBytes: item.size,
                                isReady: item.isReady, statusText: item.isReady ? nil : item.downloadState,
                                files: item.videoFiles.map {
                                    LibraryFile(id: "\(item.id):\($0.id)", name: $0.shortName ?? $0.name, sizeBytes: $0.size,
                                                locatorHint: .torbox(kind: kind, itemID: item.id, fileID: $0.id))
                                })
                }
            } catch TorBoxError.api(let code, _) where code == "NO_AUTH" || code == "BAD_TOKEN" {
                throw SourceError.needsCredentials
            }
        }
        return Page(items: items)
    }

    public func resolve(_ hint: LocatorHint) async throws -> PlaybackLocator {
        guard case .torbox(let kind, let itemID, let fileID) = hint else { throw SourceError.unsupported }
        let url = try await client.downloadLink(kind: kind, itemID: itemID, fileID: fileID)
        return PlaybackLocator(url: url, expiresAt: Date().addingTimeInterval(3 * 3600))
    }
}
