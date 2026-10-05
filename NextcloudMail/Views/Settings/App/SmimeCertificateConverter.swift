// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security

/// Turns a PKCS #12 file into the PEM certificate and private key `SettingsCommands.importSMIME`
/// uploads, on this Mac.
///
/// The web client does the same in the browser with node-forge (`src/util/pkcs12.js`), so the
/// server never sees the PKCS #12 password; this is the native equivalent. The password is a
/// parameter of ``pemPair(fromPKCS12:password:)`` and goes nowhere but the `SecPKCS12Import`
/// options dictionary: it is not stored, not logged, and not part of any thrown error.
///
/// `kSecImportToMemoryOnly` keeps the identity out of the login keychain — importing a
/// certificate into Nextcloud must not silently install it into the user's keychain too — and
/// is what makes the private key exportable with `SecKeyCopyExternalRepresentation`.
enum SmimeCertificateConverter {
    struct PEMPair: Equatable, Sendable {
        /// The leaf certificate, then the rest of the chain the file carried, as the web joins
        /// every certificate bag.
        let certificate: Data
        let privateKey: Data
    }

    enum ConversionError: Error, Equatable {
        /// Wrong password, or not a PKCS #12 file at all; `SecPKCS12Import` cannot tell the two
        /// apart reliably and neither can the web client.
        case unreadable
        /// No identity, or more than one: the server stores one certificate and one key.
        case notExactlyOneIdentity
        /// The key is of a type this converter cannot write as PEM (anything but RSA and the
        /// three NIST curves).
        case unsupportedKey

        /// The web client's messages, verbatim (`SmimeCertificateModal.vue`).
        var message: String {
            switch self {
            case .unreadable:
                String(localized: "Failed to import the certificate. Please check the password.")
            case .notExactlyOneIdentity:
                String(
                    localized:
                        "The provided PKCS #12 certificate must contain at least one certificate and exactly one private key."
                )
            case .unsupportedKey:
                String(localized: "Failed to import the certificate")
            }
        }
    }

    static func pemPair(fromPKCS12 data: Data, password: String) throws(ConversionError) -> PEMPair {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true,
        ]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else { throw .unreadable }
        let items = (rawItems as? [[String: Any]]) ?? []
        let identities = items.compactMap { $0[kSecImportItemIdentity as String] }
        guard identities.count == 1, let item = items.first(where: { $0[kSecImportItemIdentity as String] != nil }),
            let raw = item[kSecImportItemIdentity as String].map({ $0 as AnyObject }),
            CFGetTypeID(raw) == SecIdentityGetTypeID()
        else { throw .notExactlyOneIdentity }
        // The type id was checked on the line above, which is the invariant this cast needs.
        let identity = unsafeDowncast(raw, to: SecIdentity.self)

        var leaf: SecCertificate?
        var key: SecKey?
        guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf,
            SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key
        else { throw .notExactlyOneIdentity }

        let chain = (item[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        var certificates = [leaf]
        let leafData = SecCertificateCopyData(leaf) as Data
        certificates += chain.filter { SecCertificateCopyData($0) as Data != leafData }

        let certificatePEM = certificates.map { pem(label: "CERTIFICATE", der: SecCertificateCopyData($0) as Data) }
            .joined()
        return PEMPair(certificate: Data(certificatePEM.utf8), privateKey: Data(try privateKeyPEM(key).utf8))
    }

    // MARK: - Private key

    /// `SecKeyCopyExternalRepresentation` gives PKCS #1 DER for RSA, which is the PEM
    /// "RSA PRIVATE KEY" body as is, and ANSI X9.63 (`04 ‖ X ‖ Y ‖ K`) for elliptic curves,
    /// which has to be wrapped into SEC 1's `ECPrivateKey` to be the "EC PRIVATE KEY" OpenSSL
    /// reads. node-forge only writes RSA, so the EC path is a strict superset of the web.
    static func privateKeyPEM(_ key: SecKey) throws(ConversionError) -> String {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
            let type = attributes[kSecAttrKeyType as String] as? String,
            let external = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { throw .unsupportedKey }
        if type == kSecAttrKeyTypeRSA as String {
            return pem(label: "RSA PRIVATE KEY", der: external)
        }
        if type == kSecAttrKeyTypeECSECPrimeRandom as String {
            return pem(label: "EC PRIVATE KEY", der: try sec1(x963: external))
        }
        throw .unsupportedKey
    }

    /// `ECPrivateKey ::= SEQUENCE { version 1, privateKey OCTET STRING, [0] curve OID,
    /// [1] publicKey BIT STRING }` (RFC 5915).
    static func sec1(x963: Data) throws(ConversionError) -> Data {
        let bytes = [UInt8](x963)
        guard bytes.first == 0x04, (bytes.count - 1) % 3 == 0 else { throw .unsupportedKey }
        let size = (bytes.count - 1) / 3
        let curve: [UInt8]
        switch size {
        case 32: curve = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]  // P-256
        case 48: curve = [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22]  // P-384
        case 66: curve = [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x23]  // P-521
        default: throw .unsupportedKey
        }
        let publicKey = Array(bytes[0..<(1 + 2 * size)])
        let privateKey = Array(bytes[(1 + 2 * size)...])
        let body =
            der(0x02, [0x01])
            + der(0x04, privateKey)
            + der(0xA0, curve)
            + der(0xA1, der(0x03, [0x00] + publicKey))
        return Data(der(0x30, body))
    }

    static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + derLength(content.count) + content
    }

    static func derLength(_ length: Int) -> [UInt8] {
        guard length >= 0x80 else { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func pem(label: String, der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }
}
