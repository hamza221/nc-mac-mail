// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

public import Foundation

/// A `multipart/form-data` body for the two upload routes:
/// `POST /api/attachments` (field `attachment`) and
/// `POST /api/smime/certificates` (fields `certificate` and `privateKey`).
///
/// Hand-rolled because `URLSession` offers no multipart encoder and the needs
/// here are two fields and a file. The boundary is random per form, so a body
/// that happens to contain a previous boundary string cannot break framing.
public struct MultipartForm: Sendable {
    /// One form part: a plain value or a file.
    public struct Part: Sendable {
        let name: String
        let filename: String?
        let contentType: String?
        let data: Data

        /// A plain text field, such as `accountId`.
        public static func field(name: String, value: String) -> Part {
            Part(name: name, filename: nil, contentType: nil, data: Data(value.utf8))
        }

        /// A file field. `filename` reaches the server verbatim and becomes the
        /// attachment's name, so the caller passes the user-visible one.
        public static func file(name: String, filename: String, contentType: String, data: Data) -> Part {
            Part(name: name, filename: filename, contentType: contentType, data: data)
        }
    }

    public let boundary: String
    public private(set) var parts: [Part]

    public init(parts: [Part] = []) {
        // 16 random bytes of hex: ASCII, never in headers, practically
        // collision-free against part contents.
        boundary = "ncmail-" + (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        self.parts = parts
    }

    public mutating func append(_ part: Part) {
        parts.append(part)
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// RFC 7578 encoding. Quotes and backslashes in names are escaped; CR and
    /// LF are dropped outright, because a header value cannot carry them and a
    /// filename that needs them does not exist.
    func encoded() -> Data {
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(Self.escape(part.name))\""
            if let filename = part.filename {
                disposition += "; filename=\"\(Self.escape(filename))\""
            }
            body.append(Data("\(disposition)\r\n".utf8))
            if let contentType = part.contentType {
                body.append(Data("Content-Type: \(contentType)\r\n".utf8))
            }
            body.append(Data("\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
