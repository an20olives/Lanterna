import Foundation
import Testing
@testable import LanternaKit

/// Runs against the real Keychain of the host. Uses a test-only service so it never touches app items.
@Suite(.serialized)
struct KeychainStoreTests {
    let store = KeychainStore(service: "lanterna.tests.\(UUID().uuidString)")

    @Test func roundTripsAndOverwrites() throws {
        try store.set("first", for: .torboxAPIKey)
        #expect(try store.string(for: .torboxAPIKey) == "first")
        try store.set("second", for: .torboxAPIKey)
        #expect(try store.string(for: .torboxAPIKey) == "second")
        try store.remove(.torboxAPIKey)
    }

    @Test func missingItemIsNilNotAnError() throws {
        #expect(try store.string(for: .aiostreamsManifestURL) == nil)
    }

    @Test func removeIsIdempotent() throws {
        try store.remove(.tmdbReadToken)
        try store.remove(.tmdbReadToken)
    }

    @Test func defaultServiceIsConstantNotBundleID() {
        #expect(KeychainStore.defaultService == "lanterna")
    }
}
