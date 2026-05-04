import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum ImageEncodingError: LocalizedError {
    case unsupportedPlatform
    case invalidImage
    case couldNotCreateDestination
    case couldNotFinalize

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: "Image attachments are not supported on this platform"
        case .invalidImage: "Could not read image data"
        case .couldNotCreateDestination: "Could not create JPEG image data"
        case .couldNotFinalize: "Could not encode JPEG image data"
        }
    }
}

/// Encodes chat image attachments off the main actor.
enum ImageEncoder {
    static let promptImageLongEdge: CGFloat = 1568
    static let thumbnailLongEdge: CGFloat = 256
    static let jpegQuality: CGFloat = 0.85
    static let maxImagesPerMessage = 5

    static func encodeImage(data: Data, fileName: String) async throws -> ChatImageAttachment {
        try await Task.detached(priority: .userInitiated) {
            try encodeImageSync(data: data, fileName: fileName)
        }.value
    }

    static func encodeImage(url: URL) async throws -> ChatImageAttachment {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return try encodeImageSync(data: data, fileName: url.lastPathComponent)
        }.value
    }

    #if os(macOS)
    static func encodeImage(_ image: NSImage, fileName: String = "Pasted Image.jpg") async throws -> ChatImageAttachment {
        guard let tiff = image.tiffRepresentation else { throw ImageEncodingError.invalidImage }
        return try await encodeImage(data: tiff, fileName: fileName)
    }
    #elseif os(iOS)
    static func encodeImage(_ image: UIImage, fileName: String = "Pasted Image.jpg") async throws -> ChatImageAttachment {
        guard let data = image.pngData() ?? image.jpegData(compressionQuality: jpegQuality) else {
            throw ImageEncodingError.invalidImage
        }
        return try await encodeImage(data: data, fileName: fileName)
    }
    #endif

    private static func encodeImageSync(data: Data, fileName: String) throws -> ChatImageAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageEncodingError.invalidImage
        }

        let fullImage = try resizedJPEGData(from: cgImage, longEdge: promptImageLongEdge)
        let thumbnail = try resizedJPEGData(from: cgImage, longEdge: thumbnailLongEdge)
        let size = scaledSize(width: cgImage.width, height: cgImage.height, longEdge: promptImageLongEdge)

        return ChatImageAttachment(
            fileName: normalizedJPEGFileName(fileName),
            mimeType: "image/jpeg",
            dataBase64: fullImage.base64EncodedString(),
            thumbnailBase64: thumbnail.base64EncodedString(),
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded())
        )
    }

    private static func resizedJPEGData(from image: CGImage, longEdge: CGFloat) throws -> Data {
        let size = scaledSize(width: image.width, height: image.height, longEdge: longEdge)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(size.width.rounded()),
                height: Int(size.height.rounded()),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw ImageEncodingError.invalidImage
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))

        guard let resized = context.makeImage() else {
            throw ImageEncodingError.invalidImage
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageEncodingError.couldNotCreateDestination
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImagePropertyOrientation: 1,
        ]
        CGImageDestinationAddImage(destination, resized, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncodingError.couldNotFinalize
        }
        return mutableData as Data
    }

    private static func scaledSize(width: Int, height: Int, longEdge: CGFloat) -> CGSize {
        let w = CGFloat(width)
        let h = CGFloat(height)
        let maxEdge = max(w, h)
        guard maxEdge > longEdge else { return CGSize(width: w, height: h) }
        let scale = longEdge / maxEdge
        return CGSize(width: w * scale, height: h * scale)
    }

    private static func normalizedJPEGFileName(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return (base.isEmpty ? "Image" : base) + ".jpg"
    }
}
