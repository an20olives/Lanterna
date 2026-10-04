import Foundation
import Testing
@testable import LanternaKit

@Suite(.timeLimit(.minutes(1)))
struct PairingTransportTests {
    @Test func bundleCrossesALoopbackConnection() async throws {
        let server = PairingServer(lifetime: 300)
        let invitation = try await server.start(host: "127.0.0.1", advertise: false)
        defer { server.stop() }

        async let tvSide: PairingMessage = {
            var iterator = server.connections.makeAsyncIterator()
            guard let channel = await iterator.next() else { throw PairingError.unexpectedFrame }
            let message = try await channel.receive()
            try await channel.send(.result(PairingResult(applied: ["tmdb": "ok"])))
            return message
        }()

        let client = try await PairingClient.connect(invitation: invitation, deviceName: "Test iPhone", timeout: 5)
        try await client.send(.bundle(PairingProtocolTests.sampleBundle))
        let reply = try await client.receive()
        guard case .result(let result) = reply else { Issue.record("expected result"); return }
        #expect(result.applied["tmdb"] == "ok")

        guard case .bundle(let bundle) = try await tvSide else { Issue.record("expected bundle"); return }
        #expect(bundle.secrets.count == 3)
        #expect(client.peerName == "Apple TV")
    }

    @Test func aClientWithTheWrongSecretIsRejectedAndCounted() async throws {
        let server = PairingServer(lifetime: 300)
        let invitation = try await server.start(host: "127.0.0.1", advertise: false)
        defer { server.stop() }
        var forged = invitation
        forged.pairSecret = Data(repeating: 1, count: 16)
        await #expect(throws: (any Error).self) {
            _ = try await PairingClient.connect(invitation: forged, deviceName: "Mallory", timeout: 5)
        }
        var iterator = server.events.makeAsyncIterator()
        var sawFailure = false
        while let event = await iterator.next() {
            if case .failedAttempt(let count) = event { #expect(count == 1); sawFailure = true; break }
        }
        #expect(sawFailure)
    }

    @Test func serverStopsAfterThreeFailures() async throws {
        let server = PairingServer(lifetime: 300)
        let invitation = try await server.start(host: "127.0.0.1", advertise: false)
        defer { server.stop() }
        var forged = invitation
        forged.pairSecret = Data(repeating: 1, count: 16)
        var iterator = server.events.makeAsyncIterator()
        var sawLockout = false
        for attempt in 1...3 {
            _ = try? await PairingClient.connect(invitation: forged, deviceName: "Mallory", timeout: 3)
            // Wait for the server to record this failure before the next try, so its single slot is free again.
            while let event = await iterator.next() {
                if case .failedAttempt(let count) = event, count == attempt { break }
            }
        }
        while let event = await iterator.next() {
            if case .lockedOut = event { sawLockout = true; break }
        }
        #expect(sawLockout)
    }
}
