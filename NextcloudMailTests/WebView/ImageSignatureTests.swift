// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import NextcloudMail

/// The proxy labels every image `application/octet-stream`, so these signatures are the only
/// thing standing between "remote images load" and "remote images never load", and between
/// an image and an HTML or SVG document reaching the WebView.
@Suite("Image signature")
struct ImageSignatureTests {
    @Test(
        "the raster formats mail actually carries are recognised from their bytes",
        arguments: [
            ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D], "image/png"),
            ([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46], "image/jpeg"),
            (Array("GIF89a\u{01}\u{00}".utf8), "image/gif"),
            (Array("RIFF\u{00}\u{00}\u{00}\u{00}WEBPVP8 ".utf8), "image/webp"),
            ([0x00, 0x00, 0x00, 0x1C] + Array("ftypavif".utf8), "image/avif"),
        ] as [([UInt8], String)]
    )
    func recognisesRaster(bytes: [UInt8], mime: String) {
        #expect(ImageSignature.mimeType(of: Data(bytes)) == mime)
    }

    @Test(
        "documents, SVG, and fragments too short to be an image are refused",
        arguments: [
            Array("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8),
            Array("<?xml version=\"1.0\"?><svg/>".utf8),
            Array("<!DOCTYPE html><html>".utf8),
            [0x89, 0x50, 0x4E],
            [],
        ] as [[UInt8]]
    )
    func refusesEverythingElse(bytes: [UInt8]) {
        #expect(ImageSignature.mimeType(of: Data(bytes)) == nil)
    }
}
