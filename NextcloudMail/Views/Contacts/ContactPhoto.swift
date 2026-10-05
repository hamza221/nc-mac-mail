// SPDX-FileCopyrightText: Hamza Mahjoubi
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import NCMailCore
import NextcloudUI
import SwiftUI
import UniformTypeIdentifiers

/// The picture side of a contact: decoding PHOTO, the square crop web Contacts makes, and
/// the file panels. Pure image work and AppKit panels; nothing here reaches the network.
enum ContactPhotoTools {
    /// Web Contacts' cropper output bound (`getCroppedCanvas({ maxWidth: 512, maxHeight: 512 })`).
    static let maxSide = 512

    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The square at `rect` (image pixels, top-left origin), scaled down to ``maxSide`` and
    /// encoded as JPEG — the same picture web Contacts would store, smaller than its PNG.
    static func croppedJPEG(_ image: CGImage, rect: CGRect) -> Data? {
        guard let cropped = image.cropping(to: rect.integral) else { return nil }
        let side = min(cropped.width, maxSide)
        guard
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// The centred square at `zoom` (1 = the largest square that fits), moved by `offset`
    /// image pixels and kept inside the image.
    static func cropRect(imageSize: CGSize, zoom: Double, center: CGPoint) -> CGRect {
        let side = min(imageSize.width, imageSize.height) / max(zoom, 1)
        let x = min(max(center.x - side / 2, 0), imageSize.width - side)
        let y = min(max(center.y - side / 2, 0), imageSize.height - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// The file extension for PHOTO's type, for Download.
    static func fileExtension(_ photo: VCardPhoto) -> String {
        let type = (photo.mediaType ?? "jpeg").lowercased()
        if type.contains("png") { return "png" }
        if type.contains("gif") { return "gif" }
        return "jpg"
    }

    @MainActor
    static func chooseImage() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
    }

    @MainActor
    static func save(_ data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            ContactsBrowser.logger.error(
                "photo download not written: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}

/// Square crop of a chosen picture: drag to move, slider to zoom, as web Contacts' cropper
/// (`aspectRatio: 1`, `dragMode: "move"`).
struct ContactPhotoCropSheet: View {
    let image: CGImage
    let onDone: (Data?) -> Void

    @Environment(\.ncTheme) private var theme
    @State private var zoom = 1.0
    @State private var center: CGPoint
    @State private var dragStart: CGPoint?

    init(image: CGImage, onDone: @escaping (Data?) -> Void) {
        self.image = image
        self.onDone = onDone
        _center = State(initialValue: CGPoint(x: Double(image.width) / 2, y: Double(image.height) / 2))
    }

    private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }

    var body: some View {
        VStack(spacing: theme.metrics.spacing.standard) {
            Text("Crop picture").font(.headline)
            GeometryReader { geometry in
                let scale = min(geometry.size.width / imageSize.width, geometry.size.height / imageSize.height)
                let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let origin = CGPoint(
                    x: (geometry.size.width - shown.width) / 2, y: (geometry.size.height - shown.height) / 2)
                let rect = ContactPhotoTools.cropRect(imageSize: imageSize, zoom: zoom, center: center)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: shown.width, height: shown.height)
                        .offset(x: origin.x, y: origin.y)
                    Rectangle()
                        .strokeBorder(.tint, lineWidth: 2)
                        .frame(width: rect.width * scale, height: rect.height * scale)
                        .offset(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStart ?? CGPoint(x: rect.midX, y: rect.midY)
                            dragStart = start
                            center = CGPoint(
                                x: start.x + value.translation.width / scale,
                                y: start.y + value.translation.height / scale)
                        }
                        .onEnded { _ in
                            let clamped = ContactPhotoTools.cropRect(imageSize: imageSize, zoom: zoom, center: center)
                            center = CGPoint(x: clamped.midX, y: clamped.midY)
                            dragStart = nil
                        }
                )
            }
            .frame(width: Self.canvas, height: Self.canvas)
            Slider(value: $zoom, in: 1...4) { Text("Zoom") }
            HStack {
                Button("Cancel", role: .cancel) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use picture") {
                    let rect = ContactPhotoTools.cropRect(imageSize: imageSize, zoom: zoom, center: center)
                    onDone(ContactPhotoTools.croppedJPEG(image, rect: rect))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.primary)
            }
        }
        .padding(theme.metrics.spacing.loose)
        .frame(width: Self.canvas + 2 * theme.metrics.spacing.loose)
    }

    /// Sheet chrome rather than a spacing token, like the contact card popover's width.
    private static let canvas = 360.0
}

/// PHOTO at full size, with Download beside it.
struct ContactPhotoFullSizeSheet: View {
    let image: NSImage
    let onDownload: () -> Void
    let onClose: () -> Void

    @Environment(\.ncTheme) private var theme

    var body: some View {
        VStack(spacing: theme.metrics.spacing.standard) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: Self.maxSide, maxHeight: Self.maxSide)
                .accessibilityLabel(Text("Contact picture"))
            HStack {
                Button("Download…", action: onDownload)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(theme.metrics.spacing.loose)
    }

    private static let maxSide = 640.0
}
