import Foundation

/// Stremio addon source. The manifest URL is a secret and never appears in logs or fingerprints.
public struct AIOStreamsSource: MediaSource {
    public let id: SourceID
    public let kind = SourceKind.aiostreams
    public let displayName: String
    public let capabilities: SourceCapabilities = [.catalogs, .streams, .subtitles]
    let client: AIOStreamsClient

    public init(id: SourceID, client: AIOStreamsClient, displayName: String = "AIOStreams") {
        self.id = id
        self.client = client
        self.displayName = displayName
    }

    public func health() async -> SourceHealth {
        do {
            _ = try await client.manifest()
            return .ok
        } catch AIOStreamsError.http(let status) where status == 401 || status == 403 {
            return .needsCredentials
        } catch {
            return .unreachable("AIOStreams did not answer")
        }
    }

    public func catalogs() async throws -> [CatalogDescriptor] {
        let manifest = try await client.manifest()
        return (manifest.catalogs ?? []).map {
            CatalogDescriptor(id: "\($0.type)/\($0.id)", title: $0.name ?? $0.id, kind: $0.type == "movie" ? .movie : .show)
        }
    }

    public func catalogPage(_ catalog: CatalogDescriptor, cursor: PageCursor?) async throws -> Page<TitleSummary> {
        let parts = catalog.id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw SourceError.notFound }
        let skip = cursor.flatMap { Int($0.value) } ?? 0
        let metas = try await client.catalog(type: parts[0], id: parts[1], skip: skip)
        let items = metas.compactMap { meta -> TitleSummary? in
            guard meta.id.hasPrefix("tt") else { return nil }
            // TMDB ID is resolved later (TMDBClient.find); 0 marks it unresolved.
            let kind: TitleRef.Kind = meta.type == "movie" ? .movie : .show
            return TitleSummary(ref: TitleRef(kind: kind, tmdbID: 0, imdbID: meta.id), title: meta.name, year: meta.year,
                                overview: meta.description, posterPath: nil, backdropPath: nil)
        }
        return Page(items: items, next: metas.isEmpty ? nil : PageCursor(String(skip + metas.count)))
    }

    public func streams(for request: StreamRequest) async throws -> [StreamCandidate] {
        guard let stremioID = request.title.stremioID else { throw SourceError.notFound }
        let streams: [StremioStream]
        do {
            streams = try await client.streams(type: request.title.stremioType, id: stremioID)
        } catch AIOStreamsError.http(let status) {
            throw status == 401 || status == 403 ? SourceError.needsCredentials : SourceError.http(status: status)
        } catch AIOStreamsError.malformedResponse {
            throw SourceError.malformedResponse
        }
        return streams.map { stream in
            let claimed = ClaimedFormat.parse(name: stream.name, description: stream.description, filename: stream.filename)
            let name = stream.filename ?? stream.name ?? "Stream"
            return StreamCandidate(
                id: "\(id.rawValue.uuidString):\(request.title.key):\(name):\(stream.videoSize ?? 0)",
                sourceID: id, sourceKind: .aiostreams, title: request.title, displayName: name,
                detailLines: (stream.description ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                sizeBytes: stream.videoSize, claimed: claimed, isCached: claimed.isCachedClaim, locatorHint: .url(stream.url))
        }
    }

    public func subtitles(for request: StreamRequest) async throws -> [SubtitleCandidate] {
        guard let stremioID = request.title.stremioID else { throw SourceError.notFound }
        return try await client.subtitles(type: request.title.stremioType, id: stremioID).map {
            SubtitleCandidate(id: $0.id, language: $0.language, label: $0.language.uppercased(), url: $0.url)
        }
    }

    public func resolve(_ hint: LocatorHint) async throws -> PlaybackLocator {
        guard case .url(let url) = hint else { throw SourceError.unsupported }
        return PlaybackLocator(url: url)
    }
}
