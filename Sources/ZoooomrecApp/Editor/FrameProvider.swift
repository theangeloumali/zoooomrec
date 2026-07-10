import AppKit
import AVFoundation
import CoreImage
import Foundation
import RenderEngine
import ZoomEngine
import ZoomTypes

/// Produces preview frames from the recording, cropped to the zoom rect for a given time.
///
/// Scrubbing fires a request per pointer move, so each new request cancels the one in flight
/// (`cancelAllCGImageGeneration` + a monotonic request id) and only the latest result is
/// delivered — dragging stays responsive. Generation and the CoreImage crop run off the main
/// thread inside `AVAssetImageGenerator`'s completion queue; the finished `NSImage` is handed
/// back on the main thread.
///
/// For a **v2** bundle (`cursorBurnedIn == false`) the preview composites the *same* synthetic
/// pointer the exporter draws, via `CursorRenderer.composite`, so the editor stays WYSIWYG. A
/// **v1** bundle already has the real pointer baked into its pixels, so its cursor track is left
/// empty and nothing extra is drawn (never two pointers).
///
/// `@unchecked Sendable`: the only mutable state (`latestRequestID`) is guarded by `lock`, and
/// `AVAssetImageGenerator` / `CIContext` are themselves thread-safe. `cursorMoves` is an
/// immutable snapshot read once at init.
final class FrameProvider: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private let manifestSize: CGSize
    private let lock = NSLock()
    private var latestRequestID = 0

    /// The bundle's `move` samples, used to reconstruct the synthetic pointer at preview time.
    /// Empty for a v1 (cursor-burned-in) bundle and whenever the surrounding bundle can't be
    /// read — either way the preview simply skips cursor compositing.
    ///
    /// Sourced here from the video's own bundle rather than passed in, because `FrameProvider`
    /// is constructed by `EditorModel`, a file this packet does not own. When that seam opens
    /// up, thread `moves` + `cursorIsBurnedIn` down through the initializer instead of
    /// re-reading the bundle.
    private let cursorMoves: [InputEvent]

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
        cursorMoves = FrameProvider.loadCursorMoves(for: asset)
    }

    /// Reads the `move` track from the `.zoooomrec` bundle that owns `asset`'s video, but only
    /// for a v2 bundle that dropped the burned-in pointer. Reuses `EditorBundle` (the existing
    /// reader) rather than forking a second parser. Any failure — non-URL asset, unreadable
    /// bundle, or a v1 bundle — yields an empty track, so the preview degrades to no synthetic
    /// cursor instead of crashing.
    private static func loadCursorMoves(for asset: AVAsset) -> [InputEvent] {
        guard let videoURL = (asset as? AVURLAsset)?.url else { return [] }
        let bundleURL = videoURL.deletingLastPathComponent()
        guard let bundle = try? EditorBundle(bundleURL: bundleURL),
              !bundle.manifest.cursorIsBurnedIn else { return [] }
        return bundle.events.filter { $0.kind == .move }
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
            let image = self.cropped(cgImage, atTime: time, to: crop)
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

    /// Crops the decoded frame to the zoom rect, composites the synthetic cursor (v2 bundles
    /// only), and returns it as an `NSImage`.
    ///
    /// `crop` is in full capture-space pixels (top-left origin); the decoded frame may be
    /// smaller because of `maximumSize`, so the rect is scaled by the decode ratio. CoreImage
    /// uses a bottom-left origin, so the rect is flipped in Y before cropping — the same bridge
    /// `ZoomRenderer` performs at its CoreImage boundary. The cursor is drawn by
    /// `CursorRenderer.composite`, which maps the capture-space pointer through this same crop
    /// onto the cropped output, so the preview and the exported video place it identically.
    private func cropped(_ cgImage: CGImage, atTime time: Double, to crop: Rect?) -> NSImage {
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
        let composited = compositeCursor(over: cropped, crop: crop, at: time, outputSize: cropRect.size)
        guard let output = context.createCGImage(composited, from: CGRect(origin: .zero, size: cropRect.size)) else {
            return full
        }
        return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
    }

    /// Draws the smoothed synthetic pointer over the cropped frame for a v2 bundle; returns the
    /// image untouched when there is no cursor track or no cursor is visible at `time`.
    /// `outputSize` is the cropped image's extent, which `CursorRenderer` maps the pointer into.
    private func compositeCursor(over image: CIImage, crop: Rect, at time: Double, outputSize: CGSize) -> CIImage {
        guard !cursorMoves.isEmpty,
              let cursor = CursorTrack.frame(at: time, moves: cursorMoves) else { return image }
        return CursorRenderer.composite(
            cursor: cursor,
            over: image,
            crop: crop,
            outputWidth: Double(outputSize.width),
            outputHeight: Double(outputSize.height))
    }
}
