import Foundation

/// Scrub-preview thumbnails for Engine A, published as an HLS image playlist (`EXT-X-IMAGE-STREAM-INF`).
/// AVPlayerViewController shows them above the scrub bar. `fetch` returns one JPEG sheet by index.
public struct ThumbnailTrack: Sendable {
    public var width: Int
    public var height: Int
    public var columns: Int
    public var rows: Int
    public var thumbnailCount: Int
    public var intervalSeconds: Double
    public var bandwidth: Int
    public var fetch: @Sendable (Int) async throws -> Data

    public init(width: Int, height: Int, columns: Int, rows: Int, thumbnailCount: Int, intervalSeconds: Double, bandwidth: Int,
                fetch: @escaping @Sendable (Int) async throws -> Data) {
        self.width = width
        self.height = height
        self.columns = columns
        self.rows = rows
        self.thumbnailCount = thumbnailCount
        self.intervalSeconds = intervalSeconds
        self.bandwidth = bandwidth
        self.fetch = fetch
    }

    public var thumbnailsPerSheet: Int { max(columns * rows, 1) }
    public var sheetCount: Int { (thumbnailCount + thumbnailsPerSheet - 1) / thumbnailsPerSheet }
    public static let playlistURI = "t/index.m3u8"

    /// Line for the master playlist.
    public var masterLine: String {
        "#EXT-X-IMAGE-STREAM-INF:BANDWIDTH=\(max(bandwidth, 1)),RESOLUTION=\(width)x\(height),CODECS=\"jpeg\",URI=\"\(Self.playlistURI)\""
    }

    /// The image media playlist: one entry per sheet, each covering `thumbnailsPerSheet` intervals.
    public func playlist() -> String {
        let sheetSeconds = intervalSeconds * Double(thumbnailsPerSheet)
        var lines = [
            "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int(sheetSeconds.rounded(.up)))",
            "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-IMAGES-ONLY",
            "#EXT-X-TILES:RESOLUTION=\(width)x\(height),LAYOUT=\(columns)x\(rows),DURATION=\(Self.format(intervalSeconds))",
        ]
        for sheet in 0..<sheetCount {
            let inSheet = min(thumbnailsPerSheet, thumbnailCount - sheet * thumbnailsPerSheet)
            lines.append("#EXTINF:\(Self.format(Double(inSheet) * intervalSeconds)),")
            lines.append("\(sheet).jpg")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    static func format(_ value: Double) -> String { String(format: "%.3f", value) }
}
