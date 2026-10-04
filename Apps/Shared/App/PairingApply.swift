import Foundation
import LanternaKit

extension AppEnvironment {
    /// What this device can offer to another one, for the iPhone's consent list.
    struct PairingOffer: Identifiable {
        var id: String
        var label: String
        var secret: PairingSecret?
        var isSettings: Bool = false
    }

    func pairingOffers() -> [PairingOffer] {
        var offers: [PairingOffer] = []
        if let value = secret(.aiostreamsManifestURL) { offers.append(.init(id: "aio", label: "AIOStreams link", secret: .aiostreamsManifestURL(value))) }
        if let value = secret(.tmdbReadToken) { offers.append(.init(id: "tmdb", label: "TMDB token", secret: .tmdbReadToken(value))) }
        if let value = secret(.torboxAPIKey) { offers.append(.init(id: "torbox", label: "TorBox key", secret: .torboxAPIKey(value))) }
        if let id = secret(.traktClientID), let secretValue = secret(.traktClientSecret) {
            offers.append(.init(id: "trakt", label: "Trakt app credentials", secret: .traktAppCredentials(clientID: id, clientSecret: secretValue)))
        }
        for source in config.sources where source.kind == .jellyfin {
            guard let server = source.serverURL else { continue }
            offers.append(.init(id: "jf-\(source.id)", label: "Jellyfin: \(source.name)",
                                secret: .jellyfin(sourceID: source.id, serverURL: server, remoteURL: source.remoteURL, quickConnect: true)))
        }
        offers.append(.init(id: "settings", label: "Services, shelves and player settings", secret: nil, isSettings: true))
        return offers
    }

    /// Applies a bundle from the paired phone. A bad item never stops the rest.
    func apply(_ bundle: PairingBundle) -> PairingResult {
        var applied: [String: String] = [:]
        for secretItem in bundle.secrets {
            switch secretItem {
            case .aiostreamsManifestURL(let value):
                if let url = URL(string: value), AIOStreamsClient(manifestURL: url) != nil {
                    try? keychain.set(value, for: .aiostreamsManifestURL); applied[secretItem.label] = "ok"
                } else { applied[secretItem.label] = "failed: not a manifest link" }
            case .tmdbReadToken(let value):
                try? keychain.set(value, for: .tmdbReadToken); applied[secretItem.label] = "ok"
            case .torboxAPIKey(let value):
                try? keychain.set(value, for: .torboxAPIKey); applied[secretItem.label] = "ok"
            case .traktAppCredentials(let id, let secretValue):
                try? keychain.set(id, for: .traktClientID)
                try? keychain.set(secretValue, for: .traktClientSecret)
                applied[secretItem.label] = "ok"
            case .jellyfin(let sourceID, let serverURL, let remoteURL, _):
                guard URL(string: serverURL) != nil else { applied[secretItem.label] = "failed: bad address"; continue }
                updateConfig {
                    $0.sources.removeAll { $0.id == sourceID }
                    $0.sources.append(SourceConfig(id: sourceID, kind: .jellyfin, name: URL(string: serverURL)?.host ?? "Jellyfin",
                                                   order: $0.sources.count, serverURL: serverURL, remoteURL: remoteURL))
                }
                applied[secretItem.label] = "waiting for sign-in"
            }
        }
        if let incoming = bundle.config {
            updateConfig { current in
                // Incoming wins per field; shelves are replaced as a set; local Jellyfin sources survive.
                let jellyfin = current.sources.filter { $0.kind == .jellyfin }
                current.subscribedServices = incoming.subscribedServices
                current.watchRegion = incoming.watchRegion
                current.shelves = incoming.shelves
                current.streamPrefs = incoming.streamPrefs
                current.playerPrefs = incoming.playerPrefs
                current.sources = jellyfin
            }
            applied["Settings"] = "ok"
        }
        rebuild()
        return PairingResult(applied: applied)
    }

    /// TV side: gets its own Jellyfin token through Quick Connect, with the phone approving over the sealed channel.
    func signInToJellyfinViaPhone(sourceID: UUID, channel: PairingChannel) async -> Bool {
        guard let source = config.sources.first(where: { $0.id == sourceID }), let server = source.serverURL.flatMap(URL.init(string:)) else { return false }
        let client = JellyfinClient(baseURL: server, device: JellyfinDevice(deviceID: jellyfinDeviceID(), deviceName: deviceName, version: "0.1"), token: nil, userID: nil)
        guard let session = try? await client.quickConnectInitiate() else { return false }
        try? await channel.send(.quickConnectCode(sourceID: sourceID, code: session.code))
        // The phone answers with quickConnectDone once it has authorised the code.
        for _ in 0..<40 {
            try? await Task.sleep(for: .seconds(2))
            if (try? await client.quickConnectAuthenticated(secret: session.secret)) == true,
               let auth = try? await client.authenticateWithQuickConnect(secret: session.secret) {
                try? keychain.set(auth.accessToken, account: "jellyfin.\(sourceID.uuidString).token")
                updateConfig { config in
                    if let index = config.sources.firstIndex(where: { $0.id == sourceID }) { config.sources[index].userID = auth.userID }
                }
                rebuild()
                return true
            }
        }
        return false
    }

    /// Phone side: approves the TV's Quick Connect code using this device's own Jellyfin login.
    func authorizeQuickConnect(sourceID: UUID, code: String) async -> Bool {
        guard let source = config.sources.first(where: { $0.id == sourceID }), let server = source.serverURL.flatMap(URL.init(string:)),
              let token = (try? keychain.string(account: "jellyfin.\(sourceID.uuidString).token")) ?? nil else { return false }
        let client = JellyfinClient(baseURL: server, device: JellyfinDevice(deviceID: jellyfinDeviceID(), deviceName: deviceName, version: "0.1"), token: token, userID: source.userID)
        return (try? await client.quickConnectAuthorize(code: code)) != nil
    }
}
