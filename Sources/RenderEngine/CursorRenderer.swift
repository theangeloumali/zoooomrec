import CoreGraphics
import CoreImage
import Foundation
import ZoomTypes

/// Draws the smoothed synthetic pointer onto rendered output frames.
///
/// Public **on purpose**: the editor's live preview composites the exact same pointer, so it
/// reuses this instead of forking a second cursor path (ZR-911 already cost us one duplicate —
/// we are not adding another).
///
/// The pointer is a plain CoreGraphics path (no bundled image asset), rasterized **once** per
/// scale and cached, then placed with its **tip as the hotspot** — the tip is the click point,
/// not the sprite's corner. Position maps capture-space → output pixels through the same crop
/// the zoom used; the sprite size depends only on the output resolution, never on the crop
/// scale, so the pointer keeps a constant apparent size and cannot balloon when zoomed.
public enum CursorRenderer {
    // MARK: - Sprite geometry (design units, top-left origin, tip at (0, 0))

    /// Classic arrow outline, tip first, in design points. The body extends down-and-right from
    /// the tip so the tip doubles as the click hotspot.
    private static let arrow: [CGPoint] = [
        CGPoint(x: 0.0, y: 0.0),   // tip / hotspot
        CGPoint(x: 0.0, y: 16.0),
        CGPoint(x: 3.3, y: 12.6),
        CGPoint(x: 5.6, y: 17.9),
        CGPoint(x: 7.9, y: 16.9),
        CGPoint(x: 5.7, y: 11.7),
        CGPoint(x: 11.0, y: 11.7)
    ]

    /// Slack around the outline so the white border and soft glow are never clipped.
    private static let pad: Double = 2.5

    /// Arrow bounding box in design points, derived from ``arrow`` (tip is the (0,0) corner) so
    /// the canvas can never drift out of sync with the outline.
    private static var arrowWidth: Double { arrow.map { Double($0.x) }.max() ?? 0 }
    private static var arrowHeight: Double { arrow.map { Double($0.y) }.max() ?? 0 }

    private static var canvasWidth: Double { arrowWidth + 2 * pad }
    private static var canvasHeight: Double { arrowHeight + 2 * pad }

    /// Output height at which the pointer renders at its native design size. Above and below it
    /// the pointer scales with resolution so its apparent size stays constant — and, crucially,
    /// it is derived from the OUTPUT frame, never the zoom crop, so a 3× zoom cannot enlarge it.
    private static let referenceHeight: Double = 900.0

    // MARK: - Sprite cache

    private static let cache = SpriteCache()

    /// The arrow rasterized once per `scale` (design points → output pixels) and cached.
    ///
    /// The returned image's extent origin is bottom-left (CoreImage convention); the tip sits at
    /// ``tipOffset(spriteHeight:scale:)`` within that extent.
    public static func sprite(scale: Double) -> CIImage {
        cache.sprite(scale: max(scale, 0.0001), build: rasterize)
    }

    private static func rasterize(scale: Double) -> CIImage {
        let width = max(1, Int((canvasWidth * scale).rounded()))
        let height = max(1, Int((canvasHeight * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CIImage.empty()
        }

        // Draw in design space: top-left origin, y-down, one design unit == `scale` px.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        context.translateBy(x: CGFloat(pad), y: CGFloat(pad))

        let path = CGMutablePath()
        path.addLines(between: arrow)
        path.closeSubpath()

        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Soft glow underneath (optional polish; `pad` keeps it in-bounds).
        context.saveGState()
        context.setShadow(offset: .zero, blur: 1.5, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        context.addPath(path)
        context.setFillColor(white)
        context.fillPath()
        context.restoreGState()

        // White border, then black body on top.
        context.addPath(path)
        context.setStrokeColor(white)
        context.setLineWidth(1.6)
        context.setLineJoin(.round)
        context.strokePath()

        context.addPath(path)
        context.setFillColor(black)
        context.fillPath()

        guard let image = context.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: image)
    }

    /// Where the tip sits inside a sprite of pixel height `spriteHeight`, in the sprite's
    /// bottom-left CoreImage extent. The arrow is drawn `pad` in from the top-left, so in
    /// bottom-left space the tip is `pad*scale` from the left and `pad*scale` below the top.
    private static func tipOffset(spriteHeight: Double, scale: Double) -> CGPoint {
        CGPoint(x: CGFloat(pad * scale), y: CGFloat(spriteHeight - pad * scale))
    }

    // MARK: - Compositing

    /// Maps a capture-space cursor onto the cropped+scaled output frame and draws the pointer.
    ///
    /// - `outX = (cursor.x − crop.minX) * (outputWidth / crop.width)` (and the same for Y),
    ///   converted to CoreImage's bottom-left origin.
    /// - The sprite is placed with its **tip at that point** and its size derived only from the
    ///   output resolution, so it is not enlarged by the crop scale.
    /// - Returns `image` unchanged when the cursor is hidden (`opacity <= 0`) or lies outside
    ///   the visible crop.
    public static func composite(
        cursor: CursorFrame,
        over image: CIImage,
        crop: Rect,
        outputWidth: Double,
        outputHeight: Double
    ) -> CIImage {
        guard cursor.opacity > 0, crop.width > 0, crop.height > 0 else { return image }
        guard cursor.position.x >= crop.minX, cursor.position.x <= crop.maxX,
              cursor.position.y >= crop.minY, cursor.position.y <= crop.maxY else {
            return image
        }

        let scale = max(outputHeight / referenceHeight, 0.0001)
        let sprite = sprite(scale: scale)

        // capture-space (top-left) → output pixels (top-left) → CoreImage (bottom-left).
        let outX = (cursor.position.x - crop.minX) * (outputWidth / crop.width)
        let outYTopLeft = (cursor.position.y - crop.minY) * (outputHeight / crop.height)
        let tipX = outX
        let tipY = outputHeight - outYTopLeft

        let offset = tipOffset(spriteHeight: Double(sprite.extent.height), scale: scale)
        let dx = CGFloat(tipX) - offset.x
        let dy = CGFloat(tipY) - offset.y

        let faded: CIImage = cursor.opacity >= 1.0
            ? sprite
            : sprite.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(cursor.opacity))
                ])
        let placed = faded.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let composited = placed.applyingFilter(
            "CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: image])
        // Keep the writer's origin-aligned full-frame extent — the sprite may spill past an edge.
        return composited.cropped(to: image.extent)
    }
}

/// Thread-safe sprite cache keyed by quantized scale, so `sprite(scale:)` rasterizes once per
/// render (every frame passes the same output-derived scale) and the editor preview shares it.
private final class SpriteCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [Int: CIImage] = [:]

    func sprite(scale: Double, build: (Double) -> CIImage) -> CIImage {
        let key = Int((scale * 1000).rounded())
        lock.lock()
        if let cached = images[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let image = build(scale)
        lock.lock()
        images[key] = image
        lock.unlock()
        return image
    }
}
