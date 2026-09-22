// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation
import Security

/// Why a Keychain call failed. `errSecItemNotFound` is not among these: it is
/// a normal outcome (`load` returns `nil`, `delete` is a no-op), not an error.
public enum KeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
    case corruptItem
}

/// Where the app password lives between launches.
///
/// [security.md](../../../../docs/architecture/security.md) is explicit about the shape:
/// `kSecClassInternetPassword`, keyed by host and login name, with
/// `kSecAttrAccessibleAfterFirstUnlock`, never written anywhere else. WS-00
/// proved `SecItem*` returns `errSecSuccess` under this project's sandbox
/// entitlements and ad-hoc signature, so there is no keychain-access-group
/// workaround here — the default access group for a sandboxed app is enough.
///
/// An enum of static functions rather than a type to construct: there is
/// nothing to hold state in between calls, and every call goes straight to
/// `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete`.
public enum Keychain {
    /// Stores or replaces the app password for this server and login name.
    /// Idempotent: signing in again for the same account overwrites rather
    /// than duplicating the item.
    public static func save(_ credentials: Credentials) throws {
        try delete(server: credentials.server, loginName: credentials.loginName)

        var query = baseQuery(server: credentials.server, loginName: credentials.loginName)
        query[kSecValueData as String] = Data(credentials.appPassword.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// `nil` when there is no item for this server and login name — that is
    /// "not signed in", not an error a caller needs to handle separately.
    public static func load(server: URL, loginName: String) throws -> Credentials? {
        var query = baseQuery(server: server, loginName: loginName)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data, let appPassword = String(data: data, encoding: .utf8) else {
            throw KeychainError.corruptItem
        }
        return Credentials(server: server, loginName: loginName, appPassword: appPassword)
    }

    /// Removes the item, or does nothing if there was none. Sign-out calls
    /// this; S-01 requires that the next launch asks again afterwards.
    public static func delete(server: URL, loginName: String) throws {
        let query = baseQuery(server: server, loginName: loginName)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Every account this app has signed into, for the sidebar's account list
    /// and for offering re-authentication. Returns the server and login name
    /// only — the point of the Keychain is that the password never has to
    /// pass through here to enumerate accounts.
    public static func allAccounts() throws -> [(server: URL, loginName: String)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let items = result as? [[String: Any]] else { throw KeychainError.corruptItem }

        return items.compactMap { attributes in
            guard let loginName = attributes[kSecAttrAccount as String] as? String,
                let host = attributes[kSecAttrServer as String] as? String
            else { return nil }
            guard let server = serverURL(host: host, attributes: attributes) else { return nil }
            return (server: server, loginName: loginName)
        }
    }

    // MARK: - Query construction

    /// The attributes that identify one item, shared by every operation
    /// above. `kSecAttrServer` carries only the host — `kSecAttrProtocol`,
    /// `kSecAttrPort` and `kSecAttrPath` are what let a path-prefixed
    /// instance (`https://example.com/nextcloud`) and a bare one share a
    /// keychain without colliding.
    private static func baseQuery(server: URL, loginName: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: (server.host ?? "").lowercased(),
            kSecAttrAccount as String: loginName,
            kSecAttrProtocol as String: protocolAttribute(for: server),
        ]
        if let port = server.port {
            query[kSecAttrPort as String] = port
        }
        if !server.path.isEmpty {
            query[kSecAttrPath as String] = server.path
        }
        return query
    }

    private static func protocolAttribute(for server: URL) -> CFString {
        server.scheme?.lowercased() == "http" ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS
    }

    private static func serverURL(host: String, attributes: [String: Any]) -> URL? {
        var components = URLComponents()
        let isHTTP = (attributes[kSecAttrProtocol as String] as? String) == (kSecAttrProtocolHTTP as String)
        components.scheme = isHTTP ? "http" : "https"
        components.host = host
        if let port = attributes[kSecAttrPort as String] as? Int, port != 0 {
            components.port = port
        }
        if let path = attributes[kSecAttrPath as String] as? String, !path.isEmpty {
            components.path = path
        }
        return components.url
    }
}
