import Foundation
import os

/// One place for retry, status mapping and redacted logging. Sources talk to this, not to URLSession.
public struct HTTPClient: Sendable {
    static let log = Logger(subsystem: "lanterna", category: "http")

    let transport: any HTTPTransport
    let maxRetries: Int
    let sleep: @Sendable (TimeInterval) async -> Void

    public init(transport: any HTTPTransport = URLSessionTransport(), maxRetries: Int = 2,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.transport = transport
        self.maxRetries = maxRetries
        self.sleep = sleep
    }

    @discardableResult
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await transport.data(for: request)
                switch response.statusCode {
                case 200..<300:
                    return (data, response)
                case 401, 403:
                    throw SourceError.needsCredentials
                case 404:
                    throw SourceError.notFound
                case 429:
                    throw SourceError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
                case 500..<600 where attempt < maxRetries:
                    attempt += 1
                    Self.log.info("retry \(attempt) after HTTP \(response.statusCode) for \(Redactor.url(request.url ?? URL(fileURLWithPath: "/")), privacy: .public)")
                    await sleep(0.5 * Double(attempt))
                    continue
                default:
                    throw SourceError.http(status: response.statusCode)
                }
            } catch let error as SourceError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt < maxRetries, (error as? URLError)?.code == .timedOut {
                    attempt += 1
                    await sleep(0.5 * Double(attempt))
                    continue
                }
                // URLError text can carry the failing URL; keep only the code.
                throw SourceError.unreachable((error as? URLError).map { "network error \($0.code.rawValue)" } ?? "network error")
            }
        }
    }

    public func json<T: Decodable>(_ request: URLRequest, as type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let (data, _) = try await send(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SourceError.malformedResponse
        }
    }
}
