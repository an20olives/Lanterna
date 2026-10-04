import Foundation
import Security

public enum KeychainKey: String, Sendable, CaseIterable {
    case torboxAPIKey = "torbox.apiKey"
    case aiostreamsManifestURL = "aiostreams.manifestURL"
    case tmdbReadToken = "tmdb.readToken"
    case traktClientID = "trakt.clientID"
    case traktClientSecret = "trakt.clientSecret"
    case traktAccessToken = "trakt.accessToken"
    case traktRefreshToken = "trakt.refreshToken"
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Generic-password items in the default access group.
///
/// The service name is a constant because the sideload signer rewrites the bundle ID. Never pass an
/// access group: it would embed a team ID, which changes with the signing Apple ID.
public struct KeychainStore: Sendable {
    public static let defaultService = "lanterna"
    public let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public func string(for key: KeychainKey) throws -> String? { try string(account: key.rawValue) }
    public func set(_ value: String, for key: KeychainKey) throws { try set(value, account: key.rawValue) }
    public func remove(_ key: KeychainKey) throws { try remove(account: key.rawValue) }

    /// Free-form accounts for per-source secrets, e.g. `jellyfin.<sourceID>.token`.
    public func string(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
