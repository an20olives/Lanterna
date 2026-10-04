import Foundation

/// Payload of an outbox "scrobble" operation. No secrets, no URLs.
public struct ScrobblePayload: Codable, Sendable, Equatable {
    public var titleKey: String
    public var imdbID: String?
    public var action: String
    /// Percent, 0 to 100.
    public var progress: Double

    public init(titleKey: String, imdbID: String?, action: String, progress: Double) {
        self.titleKey = titleKey
        self.imdbID = imdbID
        self.action = action
        self.progress = progress
    }
}

/// Payload of a watchlist, history or similar list operation.
public struct ListOpPayload: Codable, Sendable, Equatable {
    public var titleKey: String
    public var imdbID: String?
    public var watchedAt: Date?

    public init(titleKey: String, imdbID: String?, watchedAt: Date? = nil) {
        self.titleKey = titleKey
        self.imdbID = imdbID
        self.watchedAt = watchedAt
    }
}
