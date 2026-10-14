import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum ImageError: Error {
    case unreadable
}

enum ImageProcessing {
    private static let maxDimension = 2048
    private static let jpegQuality = 0.88

    /// Decodes an image, fits it within 2048 px and re-encodes it ready to be sent to the API.
    /// Photos become JPEG, which also strips their metadata; images with transparency stay PNG.
    static func prepare(_ data: Data) throws -> (data: Data, mimeType: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ImageError.unreadable }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxDimension, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageError.unreadable
        }

        let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
        let transparent = !isJPEG && hasTransparency(image)
        let type = transparent ? UTType.png : UTType.jpeg

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ImageError.unreadable
        }
        let encoding: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, encoding as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.unreadable }

        return (output as Data, transparent ? "image/png" : "image/jpeg")
    }

    /// Prepares a photo and keeps it on the device, ready to be sent.
    static func store(_ data: Data) async throws -> StoredFile {
        let prepared = try prepare(data)
        return try BlobStore.save(prepared.data, mimeType: prepared.mimeType)
    }

    /// The type of an image, from its first bytes.
    static func mimeType(of data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return "image/png"
    }

    private static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return true }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            for alpha in stride(from: 3, to: buffer.count, by: 4) where buffer[alpha] < 255 {
                return true
            }
            return false
        }
    }
}

/// Decodes stored images off the main thread, scaled to what is shown, and keeps the last ones.
enum ImageLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        return cache
    }()

    static func load(_ file: StoredFile, maxPixelSize: Int?) async -> UIImage? {
        let key = "\(file.name)@\(maxPixelSize ?? 0)" as NSString
        if let image = cache.object(forKey: key) { return image }

        let url = BlobStore.url(for: file)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let maxPixelSize { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: image)
        }.value

        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
