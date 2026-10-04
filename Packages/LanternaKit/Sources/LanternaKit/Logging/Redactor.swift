import Foundation

/// Strips secrets from anything that might reach a log line.
///
/// TorBox puts the API key in the `requestdl` query, AIOStreams embeds its encrypted config in the
/// URL path, Jellyfin uses `api_key`, and CDN links are short-lived credentials themselves.
public enum Redactor {
    /// API hosts whose paths are safe to show (no secrets in the path). Their queries are still hidden.
    static let pathSafeHosts: Set<String> = ["api.torbox.app", "api.themoviedb.org", "api.trakt.tv"]

    public static func url(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host() else { return "<redacted-url>" }
        let origin = url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        let path = url.path()

        if host == "127.0.0.1" || host == "localhost" {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !parts.isEmpty else { return origin + "/" }
            return origin + "/<token>" + (parts.count > 1 ? "/" + parts.dropFirst().joined(separator: "/") : "")
        }
        if path.contains("/stremio/") || path.hasSuffix("manifest.json") {
            return origin + "/<redacted>"
        }
        if pathSafeHosts.contains(host) {
            return origin + path + (url.query() == nil ? "" : "?<redacted>")
        }
        let ext = url.pathExtension
        return origin + "/<redacted>" + (ext.isEmpty ? "" : ".\(ext)")
    }

    public static func text(_ text: String, secrets: [String] = []) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "<redacted>")
        }
        let pattern = /https?:\/\/[^\s"'<>]+/
        return result.replacing(pattern) { match in
            URL(string: String(match.output)).map(url) ?? "<redacted-url>"
        }
    }
}
