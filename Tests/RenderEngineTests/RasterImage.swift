import AVFoundation
import CoreGraphics
import Foundation

/// A decoded RGBA8 raster used for pixel-level frame comparisons in tests.
struct RasterImage {
    let width: Int
    let height: Int
    private let pixels: [UInt8] // RGBA8, row-major, bytesPerRow == width * 4

    init(_ image: CGImage) {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.width = width
        self.height = height
        self.pixels = data
    }

    /// Rec. 601 luma at a pixel (0…255), clamped to bounds.
    func luma(x: Int, y: Int) -> Double {
        let cx = min(max(0, x), width - 1)
        let cy = min(max(0, y), height - 1)
        let offset = (cy * width + cx) * 4
        let r = Double(pixels[offset])
        let g = Double(pixels[offset + 1])
        let b = Double(pixels[offset + 2])
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// Mean absolute per-channel difference (RGB only) against another raster.
    func meanAbsDiff(_ other: RasterImage) -> Double {
        let count = min(pixels.count, other.pixels.count)
        guard count > 0 else { return 0 }
        var sum = 0.0
        var channels = 0
        var index = 0
        while index < count {
            if index % 4 != 3 { // skip alpha
                sum += abs(Double(pixels[index]) - Double(other.pixels[index]))
                channels += 1
            }
            index += 1
        }
        return channels > 0 ? sum / Double(channels) : 0
    }
}

/// Decodes the exact video frame at `seconds` into a comparable raster.
func frame(from asset: AVAsset, at seconds: Double) async throws -> RasterImage {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    let image = try await generator.image(at: time).image
    return RasterImage(image)
}
