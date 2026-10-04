import CryptoKit
import Foundation
import Network

/// Length-prefixed frames over one TCP connection.
final class FramedConnection: @unchecked Sendable {
    let connection: NWConnection
    private var buffer = PairingFrameBuffer()
    private var queued: [PairingFrame] = []

    init(_ connection: NWConnection) { self.connection = connection }

    func start(queue: DispatchQueue = .global(qos: .userInitiated)) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { continuation.resume() }
                case .failed(let error): if once.claim() { continuation.resume(throwing: error) }
                case .cancelled: if once.claim() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ frame: PairingFrame) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame.encoded(), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func nextFrame() async throws -> PairingFrame {
        while queued.isEmpty {
            let chunk = try await receiveChunk()
            queued += try buffer.append(chunk)
        }
        return queued.removeFirst()
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if isComplete { continuation.resume(throwing: PairingError.malformed) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    func close() { connection.cancel() }
}

final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// An authenticated, encrypted pipe to the other device.
public final class PairingChannel: @unchecked Sendable {
    public let peerName: String
    private let connection: FramedConnection
    private let seal: @Sendable (PairingMessage) throws -> PairingFrame
    private let open: @Sendable (PairingFrame) throws -> [PairingMessage]
    private var pending: [PairingMessage]

    init(peerName: String, connection: FramedConnection, initial: [PairingMessage] = [],
         seal: @escaping @Sendable (PairingMessage) throws -> PairingFrame,
         open: @escaping @Sendable (PairingFrame) throws -> [PairingMessage]) {
        self.pending = initial
        self.peerName = peerName
        self.connection = connection
        self.seal = seal
        self.open = open
    }

    public func send(_ message: PairingMessage) async throws {
        try await connection.send(try seal(message))
    }

    public func receive() async throws -> PairingMessage {
        while pending.isEmpty {
            pending += try open(try await connection.nextFrame())
        }
        return pending.removeFirst()
    }

    public func close() { connection.close() }
}

public enum PairingServerEvent: Sendable, Equatable {
    case peerConnected(name: String)
    case failedAttempt(count: Int)
    case lockedOut
}

/// Apple TV side: listens, advertises over Bonjour and hands out authenticated channels. One peer at a time,
/// and three failed handshakes lock it so the caller can show a fresh QR code.
public final class PairingServer: @unchecked Sendable {
    public static let maxFailures = 3

    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let sessionID = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
    private let pairSecret = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    private let lifetime: TimeInterval
    private let queue = DispatchQueue(label: "lanterna.pairing.server")
    private var listener: NWListener?
    private var invitation: PairingInvitation?
    private var failures = 0
    private var busy = false

    public let connections: AsyncStream<PairingChannel>
    public let events: AsyncStream<PairingServerEvent>
    private let connectionContinuation: AsyncStream<PairingChannel>.Continuation
    private let eventContinuation: AsyncStream<PairingServerEvent>.Continuation

    public init(lifetime: TimeInterval = 300) {
        self.lifetime = lifetime
        var c1: AsyncStream<PairingChannel>.Continuation!
        connections = AsyncStream { c1 = $0 }
        connectionContinuation = c1
        var c2: AsyncStream<PairingServerEvent>.Continuation!
        events = AsyncStream { c2 = $0 }
        eventContinuation = c2
    }

    /// Starts listening and returns the invitation to show as a QR code.
    public func start(host: String, advertise: Bool = true) async throws -> PairingInvitation {
        let listener = try NWListener(using: .tcp)
        if advertise {
            let name = PairingInvitation(sessionID: sessionID, tvPublicKey: Data(), pairSecret: Data(), host: "", port: 0, expires: Date()).bonjourName
            listener.service = NWListener.Service(name: name, type: "_lanterna-pair._tcp")
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.handle(connection) }
        }
        self.listener = listener
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if gate.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): if gate.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let invitation = PairingInvitation(sessionID: sessionID, tvPublicKey: privateKey.publicKey.rawRepresentation, pairSecret: pairSecret,
                                           host: host, port: port, expires: Date().addingTimeInterval(lifetime))
        self.invitation = invitation
        return invitation
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connectionContinuation.finish()
        eventContinuation.finish()
    }

    private func claimSlot() -> Bool { queue.sync { if busy { return false }; busy = true; return true } }
    private func releaseSlot() { queue.sync { busy = false } }

    private func handle(_ nw: NWConnection) async {
        guard let invitation, claimSlot() else { nw.cancel(); return }
        let connection = FramedConnection(nw)
        do {
            try await connection.start()
                let hello = try await SourceRegistry.withTimeout(10) { try await connection.nextFrame() }
                let session = PairingReceiverSession(invitation: invitation, privateKey: privateKey)
            let replies = try session.receive(hello)
            for reply in replies { try await connection.send(reply) }
            let name = session.peerName ?? "Device"
            // Only the real phone can seal this first message; anything else counts as a failed attempt.
            let first = try await SourceRegistry.withTimeout(15) { try await connection.nextFrame() }
            _ = try session.receive(first)
            let initial = session.takeMessages()
            guard !initial.isEmpty else { throw PairingError.malformed }
            eventContinuation.yield(.peerConnected(name: name))
            let channel = PairingChannel(
                peerName: name, connection: connection, initial: initial,
                seal: { try session.send($0) },
                open: { frame in _ = try session.receive(frame); return session.takeMessages() })
            connectionContinuation.yield(channel)
            // The slot stays taken until the owner closes the channel; the TV pairs one phone per QR code.
        } catch {
            try? await connection.send(PairingFrame(type: .reject, payload: Data()))
            connection.close()
            releaseSlot()
            failures += 1
            eventContinuation.yield(.failedAttempt(count: failures))
            if failures >= Self.maxFailures {
                eventContinuation.yield(.lockedOut)
                stop()
            }
        }
    }
}

/// iPhone side.
public enum PairingClient {
    public static func connect(invitation: PairingInvitation, deviceName: String, timeout: TimeInterval = 8) async throws -> PairingChannel {
        guard !invitation.isExpired() else { throw PairingError.expired }
        let session = PairingSenderSession(invitation: invitation, deviceName: deviceName)
        let connection = try await openConnection(invitation, timeout: timeout)
        do {
            try await connection.send(session.hello())
            let welcome = try await SourceRegistry.withTimeout(timeout) { try await connection.nextFrame() }
            if welcome.type == .reject { throw PairingError.authenticationFailed }
            _ = try session.receive(welcome)
        } catch {
            connection.close()
            throw error
        }
        return PairingChannel(peerName: "Apple TV", connection: connection,
                              seal: { try session.send($0) },
                              open: { frame in _ = try session.receive(frame); return session.takeMessages() })
    }

    /// Unicast first (works across VLANs), then Bonjour by name (works when the QR address is stale).
    private static func openConnection(_ invitation: PairingInvitation, timeout: TimeInterval) async throws -> FramedConnection {
        let direct = FramedConnection(NWConnection(host: NWEndpoint.Host(invitation.host), port: NWEndpoint.Port(rawValue: invitation.port)!, using: .tcp))
        do {
            try await SourceRegistry.withTimeout(min(timeout, 4)) { try await direct.start() }
            return direct
        } catch {
            direct.close()
        }
        let endpoint = try await browse(name: invitation.bonjourName, timeout: timeout)
        let viaBonjour = FramedConnection(NWConnection(to: endpoint, using: .tcp))
        try await SourceRegistry.withTimeout(timeout) { try await viaBonjour.start() }
        return viaBonjour
    }

    private static func browse(name: String, timeout: TimeInterval) async throws -> NWEndpoint {
        let browser = NWBrowser(for: .bonjour(type: "_lanterna-pair._tcp", domain: nil), using: .tcp)
        defer { browser.cancel() }
        return try await SourceRegistry.withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint, Error>) in
                let gate = ResumeGate()
                browser.browseResultsChangedHandler = { results, _ in
                    for result in results {
                        if case .service(let serviceName, _, _, _) = result.endpoint, serviceName == name, gate.claim() {
                            continuation.resume(returning: result.endpoint)
                        }
                    }
                }
                browser.stateUpdateHandler = { state in
                    if case .failed(let error) = state, gate.claim() { continuation.resume(throwing: error) }
                }
                browser.start(queue: .global(qos: .userInitiated))
            }
        }
    }
}
