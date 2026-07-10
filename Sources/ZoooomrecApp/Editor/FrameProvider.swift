import AppKit
import AVFoundation
import CoreImage
import Foundation
import ZoomTypes

/// Produces preview frames from the recording, cropped to the zoom rect for a given time.
///
/// Scrubbing fires a request per pointer move, so each new request cancels the one in flight
/// (`cancelAllCGImageGeneration` + a monotonic request id) and only the latest result is
/// delivered — dragging stays responsive. Generation and the CoreImage crop run off the main
/// thread inside `AVAssetImageGenerator`'s completion queue; the finished `NSImage` is handed
/// back on the main thread.
///
/// `@unchecked Sendable`: the only mutable state (`latestRequestID`) is guarded by `lock`, and
/// `AVAssetImageGenerator` / `CIContext` are themselves thread-safe.
final class FrameProvider: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private let manifestSize: CGSize
    private let lock = NSLock()
    private var latestRequestID = 0

    init(asset: AVAsset, manifestSize: CGSize) {
        self.manifestSize = manifestSize
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Accurate scrubbing: land on the exact requested frame, not the nearest sync sample.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Cap the decode size — the preview is scaled to fit anyway, and a 4K decode per
        // scrub tick is needlessly slow. Aspect ratio is preserved, so the crop math scales
        // uniformly.
        generator.maximumSize = CGSize(width: 1600, height: 1600)
    }

    /// Requests the frame at `time`, cropped to `crop` (capture-space pixels, top-left origin).
    /// Supersedes any in-flight request. `completion` runs on the main thread; a superseded or
    /// failed request delivers `nil` so callers keep the last good frame.
    func requestFrame(atTime time: Double, crop: Rect?, completion: @escaping @Sendable (NSImage?) -> Void) {
        lock.lock()
        latestRequestID += 1
        let requestID = latestRequestID
        lock.unlock()

        generator.cancelAllCGImageGeneration()
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        generator.generateCGImageAsynchronously(for: cmTime) { [weak self] cgImage, _, _ in
            guard let self, self.isCurrent(requestID), let cgImage else {
                if let self, self.isCurrent(requestID) { DispatchQueue.main.async { completion(nil) } }
                return
            }
            let image = self.cropped(cgImage, to: crop)
            DispatchQueue.main.async {
                guard self.isCurrent(requestID) else { return }
                completion(image)
            }
        }
    }

    private func isCurrent(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return id == latestRequestID
    }

    /// Crops the decoded frame to the zoom rect and returns it as an `NSImage`.
    ///
    /// `crop` is in full capture-space pixels (top-left origin); the decoded frame may be
    /// smaller because of `maximumSize`, so the rect is scaled by the decode ratio. CoreImage
    /// uses a bottom-left origin, so the rect is flipped in Y before cropping — the same bridge
    /// `ZoomRenderer` performs at its CoreImage boundary.
    private func cropped(_ cgImage: CGImage, to crop: Rect?) -> NSImage {
        let full = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let crop, manifestSize.width > 0, manifestSize.height > 0 else { return full }

        let imageHeight = CGFloat(cgImage.height)
        let ratioX = CGFloat(cgImage.width) / manifestSize.width
        let ratioY = CGFloat(cgImage.height) / manifestSize.height
        let source = CIImage(cgImage: cgImage)

        let flipped = CGRect(
            x: CGFloat(crop.minX) * ratioX,
            y: imageHeight - CGFloat(crop.maxY) * ratioY,
            width: CGFloat(crop.width) * ratioX,
            height: CGFloat(crop.height) * ratioY)
        let cropRect = flipped.intersection(source.extent)
        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0 else { return full }

        let cropped = source
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        guard let output = context.createCGImage(cropped, from: CGRect(origin: .zero, size: cropRect.size)) else {
            return full
        }
        return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
    }
}
