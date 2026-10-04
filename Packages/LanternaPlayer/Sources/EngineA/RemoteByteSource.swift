import Foundation

/// Random access over HTTP with Range requests, a block cache, and read-ahead.
///
/// Reads are synchronous because FFmpeg's AVIO callbacks are. Call `read` only from GCD threads
/// (the demux queue), never from Swift concurrency's cooperative pool.
public final class RemoteByteSource: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var blockSize: Int
        public var readAheadBlocks: Int
        public var cacheBlocks: Int
        public var timeout: TimeInterval

        public init(blockSize: Int = 2 << 20, readAheadBlocks: Int = 4, cacheBlocks: Int = 32, timeout: TimeInterval = 20) {
            self.blockSize = blockSize
            self.readAheadBlocks = readAheadBlocks
            self.cacheBlocks = max(cacheBlocks, readAheadBlocks + 2)
            self.timeout = timeout
        }
    }

    public let contentLength: Int64
    public let rangeSupported: Bool
    public private(set) var bytesFetched: Int64 = 0
    public private(set) var requestCount = 0

    /// Final URL after redirects. In memory only; contains credentials for debrid CDNs.
    let url: URL
    let configuration: Configuration
    private let session: URLSession
    private let condition = NSCondition()
    private var blocks: [Int64: Data] = [:]
    private var lru: [Int64] = []
    private var inFlight: Set<Int64> = []
    private var failures: [Int64: Error] = [:]
    private var lastBlockRead: Int64 = -1

    private init(url: URL, contentLength: Int64, rangeSupported: Bool, configuration: Configuration, session: URLSession) {
        self.url = url
        self.contentLength = contentLength
        self.rangeSupported = rangeSupported
        self.configuration = configuration
        self.session = session
    }

    /// Learns the length and whether Range works, without downloading the body when it does not.
    public static func open(_ url: URL, configuration: Configuration = Configuration()) async throws -> RemoteByteSource {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = configuration.timeout
        sessionConfig.httpMaximumConnectionsPerHost = max(2, configuration.readAheadBlocks + 1)
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: sessionConfig)

        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw EngineAError("Not an HTTP response") }
        let finalURL = http.url ?? url

        if http.statusCode == 206, let total = contentRangeTotal(http.value(forHTTPHeaderField: "Content-Range")) {
            return RemoteByteSource(url: finalURL, contentLength: total, rangeSupported: true,
                                    configuration: configuration, session: session)
        }
        guard (200..<300).contains(http.statusCode) else { throw EngineAError("HTTP \(http.statusCode) opening stream") }
        return RemoteByteSource(url: finalURL, contentLength: http.expectedContentLength, rangeSupported: false,
                                configuration: configuration, session: session)
    }

    static func contentRangeTotal(_ header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...])
    }

    /// Copies up to `count` bytes at `offset` into `buffer`. Returns 0 at end of file.
    func read(at offset: Int64, into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        guard rangeSupported else { throw EngineAError("Source does not support Range requests") }
        guard offset < contentLength, count > 0 else { return 0 }
        let wanted = Int(min(Int64(count), contentLength - offset))
        var copied = 0
        while copied < wanted {
            let position = offset + Int64(copied)
            let index = position / Int64(configuration.blockSize)
            let block = try blockData(index)
            let within = Int(position - index * Int64(configuration.blockSize))
            let n = min(block.count - within, wanted - copied)
            guard n > 0 else { break }
            block.withUnsafeBytes { raw in
                (buffer + copied).copyMemory(from: raw.baseAddress! + within, byteCount: n)
            }
            copied += n
        }
        return copied
    }

    /// Async convenience for tests and diagnostics.
    public func readAsync(at offset: Int64, count: Int) async throws -> Data {
        try await Blocking.run { [self] in
            var data = Data(count: count)
            let n = try data.withUnsafeMutableBytes { try self.read(at: offset, into: $0.baseAddress!, count: count) }
            return data.prefix(n)
        }
    }

    private func blockData(_ index: Int64) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        let sequential = index == lastBlockRead || index == lastBlockRead + 1
        lastBlockRead = index
        if sequential { scheduleReadAhead(after: index) }

        while true {
            if let data = blocks[index] {
                touch(index)
                return data
            }
            if let error = failures.removeValue(forKey: index) { throw error }
            if !inFlight.contains(index) { start(index) }
            condition.wait()
        }
    }

    /// Caller holds the lock.
    private func scheduleReadAhead(after index: Int64) {
        guard configuration.readAheadBlocks > 0 else { return }
        let lastBlock = (contentLength - 1) / Int64(configuration.blockSize)
        for next in (index + 1)...min(index + Int64(configuration.readAheadBlocks), max(index + 1, lastBlock)) where next <= lastBlock {
            if blocks[next] == nil, !inFlight.contains(next) { start(next) }
        }
    }

    /// Caller holds the lock.
    private func start(_ index: Int64) {
        inFlight.insert(index)
        let lower = index * Int64(configuration.blockSize)
        let upper = min(lower + Int64(configuration.blockSize), contentLength) - 1
        var request = URLRequest(url: url)
        request.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")
        requestCount += 1
        let expected = Int(upper - lower + 1)
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.condition.lock()
            defer { self.condition.broadcast(); self.condition.unlock() }
            self.inFlight.remove(index)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, status == 206, data.count == expected {
                self.blocks[index] = data
                self.bytesFetched += Int64(data.count)
                self.touch(index)
                self.evict()
            } else {
                self.failures[index] = error ?? EngineAError("Range read failed (HTTP \(status), \(data?.count ?? 0) of \(expected) bytes)")
            }
        }.resume()
    }

    /// Caller holds the lock.
    private func touch(_ index: Int64) {
        lru.removeAll { $0 == index }
        lru.append(index)
    }

    /// Caller holds the lock.
    private func evict() {
        while lru.count > configuration.cacheBlocks {
            blocks.removeValue(forKey: lru.removeFirst())
        }
    }
}
