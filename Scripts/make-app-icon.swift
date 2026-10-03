#!/usr/bin/env swift
// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Renders NextcloudMail/Assets.xcassets/AppIcon.appiconset from Nextcloud Mail's own
// envelope glyph (img/mail.svg in nextcloud/mail, Apache-2.0) on Nextcloud blue, #0082C9
// (nextcloud.com/brand).
//
// Apple's macOS icon grid: a 1024 canvas, an 824 body inset 100, corner radius 185.4 with
// *continuous* curvature (`cornerCurve = .continuous`, the system squircle, not a circular
// arc), and the soft drop shadow system icons carry. Every size the catalog lists is drawn
// down from that one master, so they cannot drift apart.
//
//     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift Scripts/make-app-icon.swift
//
// Needs the network once, for the SVG.

import AppKit
import QuartzCore

enum IconError: Error {
    case glyphUnavailable
    case contextUnavailable
    case encodingFailed(String)
}

let svgAddress = "https://raw.githubusercontent.com/nextcloud/mail/main/img/mail.svg"
let outputDirectory = URL(fileURLWithPath: "NextcloudMail/Assets.xcassets/AppIcon.appiconset")
let blue = CGColor(srgbRed: 0x00 / 255.0, green: 0x82 / 255.0, blue: 0xC9 / 255.0, alpha: 1)

func context(_ side: Int) throws -> CGContext {
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { throw IconError.contextUnavailable }
    return ctx
}

func master(glyph: NSImage) throws -> CGImage {
    let ctx = try context(1024)
    let body = CALayer()
    body.frame = CGRect(x: 100, y: 100, width: 824, height: 824)
    body.cornerRadius = 185.4
    body.cornerCurve = .continuous
    body.backgroundColor = blue
    body.shadowColor = CGColor(gray: 0, alpha: 1)
    body.shadowOpacity = 0.28
    body.shadowRadius = 14
    body.shadowOffset = CGSize(width: 0, height: -10)
    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    root.addSublayer(body)
    root.render(in: ctx)

    // The glyph's own 32-point viewBox already leaves a margin, so 62% of the body puts
    // the envelope's visible width at about half the icon, the proportion of Apple's Mail.
    let side = 824.0 * 0.62
    let rect = CGRect(x: (1024 - side) / 2, y: (1024 - side) / 2, width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = ctx.makeImage() else { throw IconError.contextUnavailable }
    return image
}

func scaled(_ image: CGImage, to side: Int) throws -> CGImage {
    let ctx = try context(side)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let scaled = ctx.makeImage() else { throw IconError.contextUnavailable }
    return scaled
}

func run() throws {
    guard
        let svgURL = URL(string: svgAddress),
        let glyph = NSImage(data: try Data(contentsOf: svgURL))
    else { throw IconError.glyphUnavailable }

    let big = try master(glyph: glyph)
    let sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
    for (points, scale) in sizes {
        let pixels = points * scale
        let image = pixels == 1024 ? big : try scaled(big, to: pixels)
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw IconError.encodingFailed(name)
        }
        try png.write(to: outputDirectory.appending(path: name))
    }
    FileHandle.standardOutput.write(Data("wrote \(outputDirectory.path)\n".utf8))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("make-app-icon: \(error)\n".utf8))
    exit(1)
}
