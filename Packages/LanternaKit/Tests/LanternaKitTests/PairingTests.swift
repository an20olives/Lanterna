import CryptoKit
import Foundation
import Testing
@testable import LanternaKit

struct PairingProtocolTests {
    static func makeInvitation(expiresIn: TimeInterval = 300) -> (PairingInvitation, Curve25519.KeyAgreement.PrivateKey) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let invitation = PairingInvitation(sessionID: Data(repeating: 7, count: 8), tvPublicKey: key.publicKey.rawRepresentation,
                                           pairSecret: Data((0..<16).map { UInt8($0) }), host: "192.168.1.20", port: 4455,
                                           expires: Date(timeIntervalSince1970: 1_000 + expiresIn))
        return (invitation, key)
    }

    static let sampleBundle = PairingBundle(
        sentAt: Date(timeIntervalSince1970: 500), fromDeviceName: "Aro's iPhone", config: nil,
        secrets: [.aiostreamsManifestURL("https://aio.example.com/stremio/x/y/manifest.json"), .tmdbReadToken("TOK"),
                  .jellyfin(sourceID: UUID(), serverURL: "https://pi.ts.net", remoteURL: nil, quickConnect: true)])

    /// Runs a full in-memory handshake.
    static func handshake() throws -> (PairingSenderSession, PairingReceiverSession) {
        let (invitation, tvKey) = makeInvitation()
        let receiver = PairingReceiverSession(invitation: invitation, privateKey: tvKey, now: Date(timeIntervalSince1970: 1_000))
        let sender = PairingSenderSession(invitation: invitation, deviceName: "iPhone")
        let hello = sender.hello()
        let welcome = try receiver.receive(hello)
        #expect(welcome.count == 1)
        _ = try sender.receive(welcome[0])
        return (sender, receiver)
    }

    @Test func invitationRoundTripsThroughTheQRString() throws {
        let (invitation, _) = Self.makeInvitation()
        let url = invitation.url
        #expect(url.scheme == "lanterna-pair")
        let parsed = try #require(PairingInvitation(url: url))
        #expect(parsed == invitation)
        #expect(PairingInvitation(url: URL(string: "https://example.com")!) == nil)
        #expect(PairingInvitation(url: URL(string: "lanterna-pair:v2?sid=x")!) == nil)
    }

    @Test func invitationExpires() {
        let (invitation, _) = Self.makeInvitation(expiresIn: 300)
        #expect(!invitation.isExpired(now: Date(timeIntervalSince1970: 1_299)))
        #expect(invitation.isExpired(now: Date(timeIntervalSince1970: 1_301)))
    }

    @Test func verificationCodeIsSixDigitsAndStable() {
        let (invitation, _) = Self.makeInvitation()
        #expect(invitation.verificationCode.count == 6)
        #expect(invitation.verificationCode == invitation.verificationCode)
        #expect(Int(invitation.verificationCode) != nil)
    }

    @Test func framesRoundTripAcrossSplitReads() throws {
        let frame = PairingFrame(type: .sealed, payload: Data((0..<200).map { UInt8($0 % 251) }))
        let bytes = frame.encoded()
        var buffer = PairingFrameBuffer()
        var out: [PairingFrame] = []
        for chunk in stride(from: 0, to: bytes.count, by: 13) {
            out += try buffer.append(bytes[chunk..<min(chunk + 13, bytes.count)])
        }
        #expect(out == [frame])
        #expect(throws: PairingError.frameTooLarge) { var b = PairingFrameBuffer(); _ = try b.append(Data([3, 0xFF, 0xFF, 0xFF, 0xFF])) }
    }

    @Test func fullHandshakeAndBundleExchange() throws {
        let (sender, receiver) = try Self.handshake()
        let frame = try sender.send(.bundle(Self.sampleBundle))
        let received = try receiver.receive(frame)
        #expect(received.isEmpty)
        let message = try #require(receiver.takeMessages().first)
        guard case .bundle(let bundle) = message else { Issue.record("expected bundle"); return }
        #expect(bundle.fromDeviceName == "Aro's iPhone")
        #expect(bundle.secrets.count == 3)

        let result = try receiver.send(.result(PairingResult(applied: ["tmdb": "ok", "jellyfin": "failed: unreachable"])))
        _ = try sender.receive(result)
        guard case .result(let applied)? = sender.takeMessages().first else { Issue.record("expected result"); return }
        #expect(applied.applied["jellyfin"] == "failed: unreachable")
    }

    @Test func wrongPairSecretCannotComplete() throws {
        let (invitation, tvKey) = Self.makeInvitation()
        let receiver = PairingReceiverSession(invitation: invitation, privateKey: tvKey, now: Date(timeIntervalSince1970: 1_000))
        var forged = invitation
        forged.pairSecret = Data(repeating: 9, count: 16)   // an eavesdropper who guessed the rest but never saw the QR
        let attacker = PairingSenderSession(invitation: forged, deviceName: "Mallory")
        let welcome = try receiver.receive(attacker.hello())
        #expect(throws: PairingError.authenticationFailed) { _ = try attacker.receive(welcome[0]) }
    }

    @Test func aFakeReceiverIsRejectedByTheSender() throws {
        let (invitation, _) = Self.makeInvitation()
        let impostorKey = Curve25519.KeyAgreement.PrivateKey()
        let impostor = PairingReceiverSession(invitation: invitation, privateKey: impostorKey, now: Date(timeIntervalSince1970: 1_000))
        let sender = PairingSenderSession(invitation: invitation, deviceName: "iPhone")
        let welcome = try impostor.receive(sender.hello())
        #expect(throws: PairingError.authenticationFailed) { _ = try sender.receive(welcome[0]) }
    }

    @Test func tamperedAndReplayedFramesAreRejected() throws {
        let (sender, receiver) = try Self.handshake()
        let frame = try sender.send(.bundle(Self.sampleBundle))
        var tampered = frame
        tampered.payload[tampered.payload.count - 1] ^= 0x01
        #expect(throws: PairingError.authenticationFailed) { _ = try receiver.receive(tampered) }
        _ = try receiver.receive(frame)
        #expect(throws: PairingError.replay) { _ = try receiver.receive(frame) }
    }

    @Test func helloIsRejectedWhenExpiredOrWrongSession() throws {
        let (invitation, tvKey) = Self.makeInvitation(expiresIn: 10)
        let late = PairingReceiverSession(invitation: invitation, privateKey: tvKey, now: Date(timeIntervalSince1970: 5_000))
        let sender = PairingSenderSession(invitation: invitation, deviceName: "iPhone")
        #expect(throws: PairingError.expired) { _ = try late.receive(sender.hello()) }

        var other = invitation
        other.sessionID = Data(repeating: 1, count: 8)
        let wrong = PairingSenderSession(invitation: other, deviceName: "iPhone")
        let receiver = PairingReceiverSession(invitation: invitation, privateKey: tvKey, now: Date(timeIntervalSince1970: 1_000))
        #expect(throws: PairingError.wrongSession) { _ = try receiver.receive(wrong.hello()) }
    }

    @Test func eachDirectionHasItsOwnKeystreamPosition() throws {
        let (sender, receiver) = try Self.handshake()
        // The same plaintext sealed phone-to-TV and TV-to-phone must differ even at the same sequence number.
        let a = try sender.send(.result(PairingResult(applied: [:])))
        let b = try receiver.send(.result(PairingResult(applied: [:])))
        #expect(a.payload != b.payload)
    }

    @Test func quickConnectRelayMessagesCrossTheChannel() throws {
        let (sender, receiver) = try Self.handshake()
        let id = UUID()
        _ = try sender.receive(try receiver.send(.quickConnectCode(sourceID: id, code: "123456")))
        guard case .quickConnectCode(let source, let code)? = sender.takeMessages().first else { Issue.record("expected code"); return }
        #expect(source == id && code == "123456")
        _ = try receiver.receive(try sender.send(.quickConnectDone(sourceID: id, ok: true)))
        guard case .quickConnectDone(_, let ok)? = receiver.takeMessages().first else { Issue.record("expected done"); return }
        #expect(ok)
    }
}
