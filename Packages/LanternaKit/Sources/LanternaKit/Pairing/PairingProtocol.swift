import CryptoKit
import Foundation

public enum PairingError: Error, Equatable {
    case malformed
    case expired
    case wrongSession
    case unsupportedVersion
    case authenticationFailed
    case replay
    case frameTooLarge
    case unexpectedFrame
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL string: String) {
        var text = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }
}

/// What the Apple TV shows as a QR code. Whoever scans it can complete the handshake; nobody else can.
public struct PairingInvitation: Equatable, Sendable {
    public var sessionID: Data        // 8 bytes
    public var tvPublicKey: Data      // X25519, 32 bytes
    public var pairSecret: Data       // 16 bytes, only ever in the QR
    public var host: String
    public var port: UInt16
    public var expires: Date

    public init(sessionID: Data, tvPublicKey: Data, pairSecret: Data, host: String, port: UInt16, expires: Date) {
        self.sessionID = sessionID
        self.tvPublicKey = tvPublicKey
        self.pairSecret = pairSecret
        self.host = host
        self.port = port
        self.expires = expires
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "lanterna-pair"
        components.path = "v1"
        components.queryItems = [
            URLQueryItem(name: "sid", value: sessionID.base64URL), URLQueryItem(name: "pk", value: tvPublicKey.base64URL),
            URLQueryItem(name: "ps", value: pairSecret.base64URL), URLQueryItem(name: "h", value: host),
            URLQueryItem(name: "p", value: String(port)), URLQueryItem(name: "exp", value: String(Int(expires.timeIntervalSince1970))),
        ]
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == "lanterna-pair", let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.path == "v1" else { return nil }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
        guard let sid = items["sid"].flatMap(Data.init(base64URL:)), sid.count == 8,
              let pk = items["pk"].flatMap(Data.init(base64URL:)), pk.count == 32,
              let ps = items["ps"].flatMap(Data.init(base64URL:)), ps.count == 16,
              let host = items["h"], let port = items["p"].flatMap(UInt16.init), let exp = items["exp"].flatMap(TimeInterval.init) else { return nil }
        self.init(sessionID: sid, tvPublicKey: pk, pairSecret: ps, host: host, port: port, expires: Date(timeIntervalSince1970: exp))
    }

    public func isExpired(now: Date = Date()) -> Bool { now > expires }

    /// Six digits both screens show, so the owner can eyeball that the phone and TV agree. Not a secret.
    public var verificationCode: String {
        let digest = SHA256.hash(data: sessionID + tvPublicKey)
        let value = digest.prefix(3).reduce(0) { ($0 << 8) | Int($1) } >> 4   // first 20 bits
        return String(format: "%06d", value % 1_000_000)
    }

    public var bonjourName: String { "Lanterna-" + sessionID.prefix(3).map { String(format: "%02x", $0) }.joined() }
}

public enum PairingSecret: Codable, Sendable, Equatable {
    case torboxAPIKey(String)
    case aiostreamsManifestURL(String)
    case tmdbReadToken(String)
    /// The app's credentials, not a user token: each device signs in to Trakt itself.
    case traktAppCredentials(clientID: String, clientSecret: String)
    case jellyfin(sourceID: UUID, serverURL: String, remoteURL: String?, quickConnect: Bool)

    /// Short label for the consent list. Never contains the value.
    public var label: String {
        switch self {
        case .torboxAPIKey: "TorBox key"
        case .aiostreamsManifestURL: "AIOStreams link"
        case .tmdbReadToken: "TMDB token"
        case .traktAppCredentials: "Trakt app credentials"
        case .jellyfin(_, let url, _, _): "Jellyfin server \(URL(string: url)?.host ?? "")"
        }
    }
}

public struct PairingBundle: Codable, Sendable, Equatable {
    public var version = 1
    public var sentAt: Date
    public var fromDeviceName: String
    public var config: DeviceConfig?
    public var secrets: [PairingSecret]

    public init(sentAt: Date, fromDeviceName: String, config: DeviceConfig?, secrets: [PairingSecret]) {
        self.sentAt = sentAt
        self.fromDeviceName = fromDeviceName
        self.config = config
        self.secrets = secrets
    }
}

public struct PairingResult: Codable, Sendable, Equatable {
    /// Item label to "ok", "skipped" or "failed: reason".
    public var applied: [String: String]
    public init(applied: [String: String]) { self.applied = applied }
}

public enum PairingMessage: Codable, Sendable, Equatable {
    case bundle(PairingBundle)
    case result(PairingResult)
    case quickConnectCode(sourceID: UUID, code: String)
    case quickConnectDone(sourceID: UUID, ok: Bool)
}

public enum PairingFrameType: UInt8, Sendable {
    case hello = 1, welcome = 2, sealed = 3, reject = 9
}

public struct PairingFrame: Equatable, Sendable {
    public var type: PairingFrameType
    public var payload: Data
    public init(type: PairingFrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data([type.rawValue])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        return data + payload
    }
}

public struct PairingFrameBuffer: Sendable {
    public static let maxPayload = 1 << 20
    private var pending = Data()
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [PairingFrame] {
        pending.append(bytes)
        var frames: [PairingFrame] = []
        while pending.count >= 5 {
            let base = pending.startIndex
            let length = pending[(base + 1)..<(base + 5)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Self.maxPayload else { throw PairingError.frameTooLarge }
            guard pending.count >= 5 + length else { break }
            guard let type = PairingFrameType(rawValue: pending[base]) else { throw PairingError.malformed }
            frames.append(PairingFrame(type: type, payload: Data(pending[(base + 5)..<(base + 5 + length)])))
            pending = Data(pending.dropFirst(5 + length))
        }
        return frames
    }
}

enum PairingCrypto {
    static let info = Data("lanterna-pair-v1".utf8)

    static func transcript(sid: Data, tvPK: Data, phPK: Data, nonceP: Data, nonceT: Data) -> Data {
        sid + tvPK + phPK + nonceP + nonceT
    }

    static func key(shared: SharedSecret, pairSecret: Data, transcript: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: pairSecret, sharedInfo: info + transcript, outputByteCount: 32)
    }

    static func nonce(direction: UInt8, seq: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data([direction, 0, 0, 0])
        withUnsafeBytes(of: seq.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    static func aad(sid: Data, seq: UInt64, direction: UInt8) -> Data {
        var data = sid
        withUnsafeBytes(of: seq.bigEndian) { data.append(contentsOf: $0) }
        data.append(direction)
        return data
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, sid: Data, seq: UInt64, direction: UInt8) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(direction: direction, seq: seq), authenticating: aad(sid: sid, seq: seq, direction: direction))
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: SymmetricKey, sid: Data, seq: UInt64, direction: UInt8) throws -> Data {
        guard sealed.count >= 16 else { throw PairingError.malformed }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce(direction: direction, seq: seq), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return try ChaChaPoly.open(box, using: key, authenticating: aad(sid: sid, seq: seq, direction: direction))
        } catch {
            throw PairingError.authenticationFailed
        }
    }
}

private let toTV: UInt8 = 0
private let toPhone: UInt8 = 1

/// The Apple TV side of the handshake. Pure: bytes in, bytes out.
public final class PairingReceiverSession: @unchecked Sendable {
    private let invitation: PairingInvitation
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let now: Date
    private var key: SymmetricKey?
    private var nextIn: UInt64 = 1
    private var nextOut: UInt64 = 1
    private var inbox: [PairingMessage] = []
    public private(set) var peerName: String?

    public init(invitation: PairingInvitation, privateKey: Curve25519.KeyAgreement.PrivateKey, now: Date = Date()) {
        self.invitation = invitation
        self.privateKey = privateKey
        self.now = now
    }

    public var isEstablished: Bool { key != nil }

    /// Returns frames to send back.
    public func receive(_ frame: PairingFrame) throws -> [PairingFrame] {
        switch frame.type {
        case .hello:
            guard key == nil else { throw PairingError.unexpectedFrame }
            guard !invitation.isExpired(now: now) else { throw PairingError.expired }
            let p = frame.payload
            guard p.count >= 1 + 8 + 32 + 16 else { throw PairingError.malformed }
            guard p[p.startIndex] == 1 else { throw PairingError.unsupportedVersion }
            let sid = Data(p[(p.startIndex + 1)..<(p.startIndex + 9)])
            guard sid == invitation.sessionID else { throw PairingError.wrongSession }
            let phPK = Data(p[(p.startIndex + 9)..<(p.startIndex + 41)])
            let nonceP = Data(p[(p.startIndex + 41)..<(p.startIndex + 57)])
            peerName = String(decoding: p.dropFirst(57), as: UTF8.self)
            let nonceT = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: phPK)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            let transcript = PairingCrypto.transcript(sid: sid, tvPK: invitation.tvPublicKey, phPK: phPK, nonceP: nonceP, nonceT: nonceT)
            let derived = PairingCrypto.key(shared: shared, pairSecret: invitation.pairSecret, transcript: transcript)
            key = derived
            let proof = try PairingCrypto.seal(Data("tv-ok".utf8) + SHA256.hash(data: transcript).withUnsafeBytes { Data($0) }, key: derived,
                                               sid: sid, seq: 0, direction: toPhone)
            return [PairingFrame(type: .welcome, payload: nonceT + proof)]
        case .sealed:
            guard let key else { throw PairingError.unexpectedFrame }
            let p = frame.payload
            guard p.count > 8 else { throw PairingError.malformed }
            let seq = p.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard seq == nextIn else { throw seq < nextIn ? PairingError.replay : PairingError.malformed }
            let plaintext = try PairingCrypto.open(Data(p.dropFirst(8)), key: key, sid: invitation.sessionID, seq: seq, direction: toTV)
            nextIn += 1
            guard let message = try? JSONDecoder.pairing.decode(PairingMessage.self, from: plaintext) else { throw PairingError.malformed }
            inbox.append(message)
            return []
        default:
            throw PairingError.unexpectedFrame
        }
    }

    public func send(_ message: PairingMessage) throws -> PairingFrame {
        guard let key else { throw PairingError.unexpectedFrame }
        let seq = nextOut
        nextOut += 1
        let sealed = try PairingCrypto.seal(try JSONEncoder.pairing.encode(message), key: key, sid: invitation.sessionID, seq: seq, direction: toPhone)
        var payload = Data()
        withUnsafeBytes(of: seq.bigEndian) { payload.append(contentsOf: $0) }
        return PairingFrame(type: .sealed, payload: payload + sealed)
    }

    public func takeMessages() -> [PairingMessage] {
        defer { inbox = [] }
        return inbox
    }
}

/// The iPhone side. It trusts the Apple TV only if the WELCOME proof opens with a key derived from the QR's secret.
public final class PairingSenderSession: @unchecked Sendable {
    private let invitation: PairingInvitation
    private let deviceName: String
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let nonceP = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    private var key: SymmetricKey?
    private var nextIn: UInt64 = 1
    private var nextOut: UInt64 = 1
    private var inbox: [PairingMessage] = []

    public init(invitation: PairingInvitation, deviceName: String) {
        self.invitation = invitation
        self.deviceName = deviceName
    }

    public var isEstablished: Bool { key != nil }

    public func hello() -> PairingFrame {
        let payload = Data([1]) + invitation.sessionID + privateKey.publicKey.rawRepresentation + nonceP + Data(deviceName.utf8)
        return PairingFrame(type: .hello, payload: payload)
    }

    public func receive(_ frame: PairingFrame) throws -> [PairingFrame] {
        switch frame.type {
        case .welcome:
            guard key == nil else { throw PairingError.unexpectedFrame }
            let p = frame.payload
            guard p.count > 16 else { throw PairingError.malformed }
            let nonceT = Data(p.prefix(16))
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: invitation.tvPublicKey)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            let transcript = PairingCrypto.transcript(sid: invitation.sessionID, tvPK: invitation.tvPublicKey,
                                                      phPK: privateKey.publicKey.rawRepresentation, nonceP: nonceP, nonceT: nonceT)
            let derived = PairingCrypto.key(shared: shared, pairSecret: invitation.pairSecret, transcript: transcript)
            let proof = try PairingCrypto.open(Data(p.dropFirst(16)), key: derived, sid: invitation.sessionID, seq: 0, direction: toPhone)
            guard proof == Data("tv-ok".utf8) + SHA256.hash(data: transcript).withUnsafeBytes({ Data($0) }) else { throw PairingError.authenticationFailed }
            key = derived
            return []
        case .sealed:
            guard let key else { throw PairingError.unexpectedFrame }
            let p = frame.payload
            guard p.count > 8 else { throw PairingError.malformed }
            let seq = p.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard seq == nextIn else { throw seq < nextIn ? PairingError.replay : PairingError.malformed }
            let plaintext = try PairingCrypto.open(Data(p.dropFirst(8)), key: key, sid: invitation.sessionID, seq: seq, direction: toPhone)
            nextIn += 1
            guard let message = try? JSONDecoder.pairing.decode(PairingMessage.self, from: plaintext) else { throw PairingError.malformed }
            inbox.append(message)
            return []
        default:
            throw PairingError.unexpectedFrame
        }
    }

    public func send(_ message: PairingMessage) throws -> PairingFrame {
        guard let key else { throw PairingError.unexpectedFrame }
        let seq = nextOut
        nextOut += 1
        let sealed = try PairingCrypto.seal(try JSONEncoder.pairing.encode(message), key: key, sid: invitation.sessionID, seq: seq, direction: toTV)
        var payload = Data()
        withUnsafeBytes(of: seq.bigEndian) { payload.append(contentsOf: $0) }
        return PairingFrame(type: .sealed, payload: payload + sealed)
    }

    public func takeMessages() -> [PairingMessage] {
        defer { inbox = [] }
        return inbox
    }
}

extension JSONEncoder {
    static var pairing: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var pairing: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
