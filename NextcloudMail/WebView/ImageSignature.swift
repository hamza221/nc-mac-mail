// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The image type a byte buffer actually is, read from its leading signature.
///
/// A proxied remote image cannot be classified from its response: Nextcloud's
/// `ProxyController::proxy` answers every request, image or not, with
/// `Content-Type: application/octet-stream`. The bytes are the only honest witness, and
/// deciding from them is also the stricter rule: a server or upstream that *labels* HTML as
/// `image/png` gets nothing past this.
///
/// Raster formats only. SVG has no binary signature to match — it is a text document with
/// its own external references and scripting model — so it is refused by construction rather
/// than by a special case.
nonisolated enum ImageSignature {
    /// The MIME type to hand WebKit, or nil when the bytes are not an image we render.
    static func mimeType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        func starts(with prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        let ascii = { (text: String) in Array(text.utf8) }

        if starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(with: ascii("GIF87a")) || starts(with: ascii("GIF89a")) { return "image/gif" }
        if starts(with: ascii("RIFF")) && starts(with: ascii("WEBP"), at: 8) { return "image/webp" }
        if starts(with: ascii("BM")) { return "image/bmp" }
        if starts(with: [0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        if starts(with: [0x49, 0x49, 0x2A, 0x00]) || starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if starts(with: ascii("ftyp"), at: 4) {
            if starts(with: ascii("avif"), at: 8) || starts(with: ascii("avis"), at: 8) { return "image/avif" }
            if starts(with: ascii("heic"), at: 8) || starts(with: ascii("heix"), at: 8) { return "image/heic" }
        }
        return nil
    }
}
