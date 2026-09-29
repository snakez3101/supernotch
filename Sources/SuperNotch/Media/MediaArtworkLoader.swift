// Owner: media stream. Cover loading with a small cache and optional accent colour (SPEC §A.5).
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SuperNotchCore
import os

/// A decoded, downsampled cover plus its optional accent colour. Immutable after init.
nonisolated final class MediaArtworkResult: @unchecked Sendable {
    let image: NSImage
    let accent: MediaAccentColor?

    init(image: NSImage, accent: MediaAccentColor?) {
        self.image = image
        self.accent = accent
    }
}

/// Downloads covers with `URLSession` (ephemeral: no disk cache), downsamples them with ImageIO to at most
/// `maxPixelSize` and keeps the last few in an `NSCache` keyed by source. Safe to call from any thread.
nonisolated final class MediaArtworkLoader: @unchecked Sendable {
    /// 56 pt @2x = 112 px; 192 leaves headroom for scaled displays without keeping the 640 px original.
    static let maxPixelSize = 192
    private static let maxDownloadBytes = 8_000_000
    private static let accentSampleSide = 24

    private let cache = NSCache<NSString, MediaArtworkResult>()
    private let session: URLSession

    init() {
        cache.countLimit = 8
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Synchronous cache lookup (no I/O).
    func cachedResult(for source: SpotifyArtworkSource) -> MediaArtworkResult? {
        cache.object(forKey: source.cacheKey as NSString)
    }

    func load(_ source: SpotifyArtworkSource) async -> MediaArtworkResult? {
        if let cached = cachedResult(for: source) { return cached }
        do {
            let imageURL: URL
            switch source {
            case .image(let url):
                imageURL = url
            case .oEmbed(let url):
                let (data, response) = try await session.data(from: url)
                guard Self.isSuccess(response), let thumbnail = SpotifyArtworkPolicy.thumbnailURL(fromOEmbed: data)
                else { return nil }
                imageURL = thumbnail
            }
            let (data, response) = try await session.data(from: imageURL)
            guard Self.isSuccess(response), data.count <= Self.maxDownloadBytes,
                let result = Self.decode(data)
            else { return nil }
            cache.setObject(result, forKey: source.cacheKey as NSString)
            return result
        } catch {
            if !(error is CancellationError) {
                Log.media.debug("Artwork load failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    // MARK: Decoding

    private static func isSuccess(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(http.statusCode)
    }

    private static func decode(_ data: Data) -> MediaArtworkResult? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return MediaArtworkResult(image: image, accent: accentColor(of: cgImage))
    }

    /// Draws the cover into a tiny RGBA8 bitmap and lets Core pick the dominant saturated hue.
    private static func accentColor(of image: CGImage) -> MediaAccentColor? {
        let side = accentSampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        return MediaDominantColor.extract(rgba: pixels, width: side, height: side)
    }
}
