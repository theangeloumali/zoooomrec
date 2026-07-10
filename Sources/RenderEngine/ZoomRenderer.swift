import AVFoundation
import CoreImage
import Foundation
import ZoomEngine
import ZoomTypes

public struct ZoomRenderer {
    public init() {}

    /// Renders a `.zoooomrec` bundle into a zoom-animated MP4.
    ///
    /// Reads the manifest, event stream, and source video from the bundle, compiles
    /// per-frame crop rectangles from the zoom timeline, then streams every frame
    /// through CoreImage (crop + scale) and re-encodes to H.264 at the source size/fps.
    public func render(
        projectBundle: URL,
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let bundle = try RenderBundle(bundle: projectBundle)

        let asset = AVURLAsset(url: bundle.videoURL)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack(bundle.videoURL)
        }
        let naturalSize = try await track.load(.naturalSize)
        let pixelWidth = Int(abs(naturalSize.width).rounded())
        let pixelHeight = Int(abs(naturalSize.height).rounded())
        let fps = bundle.manifest.fps

        let segments = Self.compileSegments(
            manifest: bundle.manifest,
            events: bundle.events,
            duration: duration.seconds
        )
        // Cursor-follow overload: both manual and auto zooms pan toward the live cursor.
        let keyframes = ZoomTimeline.cropKeyframes(
            segments: segments,
            events: bundle.events,
            width: Double(pixelWidth),
            height: Double(pixelHeight),
            fps: fps,
            duration: duration.seconds
        )

        // Synthetic cursor: draw it only when the pointer is NOT already baked into the pixels.
        // A v1 bundle (`cursorIsBurnedIn == true`, incl. legacy nil) renders byte-for-byte as
        // before — `nil` frames leave the drain loop untouched. v2 bundles carry the pointer as
        // `move` events, smoothed into one `CursorFrame?` per output frame here.
        let cursorFrames: [CursorFrame?]? = bundle.manifest.cursorIsBurnedIn
            ? nil
            : CursorTrack.frames(
                moves: bundle.events.filter { $0.kind == .move },
                fps: fps,
                duration: duration.seconds,
                config: CursorConfig()
            )

        let (reader, readerOutput) = try makeReader(asset: asset, track: track)
        let (writer, writerInput, adaptor) = try makeWriter(
            outputURL: outputURL, width: pixelWidth, height: pixelHeight
        )

        guard reader.startReading() else { throw reader.error ?? RenderError.readerSetupFailed }
        guard writer.startWriting() else { throw writer.error ?? RenderError.writerSetupFailed }
        writer.startSession(atSourceTime: .zero)

        let pipeline = RenderPipeline(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput,
            adaptor: adaptor,
            keyframes: keyframes,
            cursorFrames: cursorFrames,
            context: CIContext(options: [.workingColorSpace: NSNull()]),
            outputWidth: pixelWidth,
            outputHeight: pixelHeight,
            fps: fps,
            estimatedFrames: max(1, Int((duration.seconds * fps).rounded())),
            progress: progress
        )
        try await pipeline.run()
        progress?(1.0)
    }

    /// Selects the zoom lane and compiles it into segments.
    ///
    /// Precedence (as shipped): explicit `manifest.segments` > hotkey markers
    /// (``ManualZoom``) > click auto-zoom (``AutoZoom``). The record-time `zoomScale`
    /// drives BOTH the manual and auto lanes — auto-zoom previously received no config
    /// and so always rendered at `AutoZoomConfig`'s 2.0 default, silently ignoring
    /// `--zoom-scale`. Extracted so the lane + scale wiring is unit-testable without a
    /// full render (see `RenderEngineTests/ZoomScaleWiringTests`).
    static func compileSegments(
        manifest: ProjectManifest,
        events: [InputEvent],
        duration: Double
    ) -> [ZoomSegment] {
        if let explicit = manifest.segments { return explicit }
        let scale = manifest.zoomScale ?? ZoomDefaults.scale
        let width = Double(manifest.pixelWidth)
        let height = Double(manifest.pixelHeight)
        let hasManualMarkers = events.contains { $0.kind == .zoomIn }
        return hasManualMarkers
            ? ManualZoom.segments(
                from: events, width: width, height: height, scale: scale, duration: duration)
            : AutoZoom.segments(
                from: events, width: width, height: height,
                config: AutoZoomConfig(zoomScale: scale))
    }

    // MARK: - Reader / writer construction

    private func makeReader(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RenderError.readerSetupFailed }
        reader.add(output)
        return (reader, output)
    }

    private func makeWriter(
        outputURL: URL,
        width: Int,
        height: Int
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        guard writer.canAdd(input) else { throw RenderError.writerSetupFailed }
        writer.add(input)
        return (writer, input, adaptor)
    }
}

/// Streams frames from reader → CoreImage → writer using the `requestMediaDataWhenReady`
/// drain pattern. All mutable state and every AVFoundation object is confined to the
/// single serial `queue`, which is what makes the `@unchecked Sendable` conformance safe.
private final class RenderPipeline: @unchecked Sendable {
    private let reader: AVAssetReader
    private let readerOutput: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let keyframes: [CropKeyframe]
    /// One entry per output frame, or `nil` for a burned-in (v1) bundle that draws no cursor.
    /// An inner `nil` means the pointer is hidden (idle-faded) on that frame.
    private let cursorFrames: [CursorFrame?]?
    private let context: CIContext
    private let outputWidth: Int
    private let outputHeight: Int
    private let fps: Double
    private let estimatedFrames: Int
    private let progress: (@Sendable (Double) -> Void)?
    private let queue = DispatchQueue(label: "zoooomrec.render.drain")

    // Touched only on `queue`.
    private var didFinish = false
    private var appended = 0

    init(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        keyframes: [CropKeyframe],
        cursorFrames: [CursorFrame?]?,
        context: CIContext,
        outputWidth: Int,
        outputHeight: Int,
        fps: Double,
        estimatedFrames: Int,
        progress: (@Sendable (Double) -> Void)?
    ) {
        self.reader = reader
        self.readerOutput = readerOutput
        self.writer = writer
        self.writerInput = writerInput
        self.adaptor = adaptor
        self.keyframes = keyframes
        self.cursorFrames = cursorFrames
        self.context = context
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.fps = fps
        self.estimatedFrames = estimatedFrames
        self.progress = progress
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) { [self] in
                pump(continuation)
            }
        }
    }

    /// Drains as many source frames as the writer will accept in one callback.
    private func pump(_ continuation: CheckedContinuation<Void, Error>) {
        while writerInput.isReadyForMoreMediaData {
            guard reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() else {
                finish {
                    writerInput.markAsFinished()
                    if reader.status == .failed {
                        writer.cancelWriting()
                        continuation.resume(throwing: reader.error ?? RenderError.readerSetupFailed)
                        return
                    }
                    writer.finishWriting { [self] in
                        if let error = writer.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                return
            }
            do {
                try processFrame(sample)
                appended += 1
                progress?(min(1.0, Double(appended) / Double(estimatedFrames)))
            } catch {
                finish {
                    writerInput.markAsFinished()
                    reader.cancelReading()
                    writer.cancelWriting()
                    continuation.resume(throwing: error)
                }
                return
            }
        }
    }

    /// Crops one source frame to its nearest keyframe rect and scales it back to full size.
    private func processFrame(_ sample: CMSampleBuffer) throws {
        try autoreleasepool {
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw RenderError.readerSetupFailed
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let imageHeight = CGFloat(CVPixelBufferGetHeight(sourceBuffer))
            let source = CIImage(cvPixelBuffer: sourceBuffer)

            var rendered = source
            // The crop the cursor maps through: the active keyframe, or the full frame when no
            // zoom is present (identity mapping, so the cursor lands at its capture position).
            var cropRect = Rect(x: 0, y: 0, width: Double(outputWidth), height: Double(outputHeight))
            if let keyframe = RenderPipeline.nearestKeyframe(keyframes, pts: pts.seconds, fps: fps) {
                cropRect = keyframe.rect
                rendered = RenderPipeline.zoom(
                    source: source,
                    rect: keyframe.rect,
                    imageHeight: imageHeight,
                    outputWidth: CGFloat(outputWidth),
                    outputHeight: CGFloat(outputHeight)
                )
            }

            // Draw the synthetic pointer after the crop/scale, indexed by the same nearest-PTS
            // logic as the crop keyframes. `nil` (burned-in) or a hidden frame leaves it untouched.
            if let cursorFrames,
               let cursor = RenderPipeline.nearestCursor(cursorFrames, pts: pts.seconds, fps: fps) {
                rendered = CursorRenderer.composite(
                    cursor: cursor,
                    over: rendered,
                    crop: cropRect,
                    outputWidth: Double(outputWidth),
                    outputHeight: Double(outputHeight)
                )
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw RenderError.pixelBufferPoolUnavailable
            }
            var destination: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
            guard status == kCVReturnSuccess, let buffer = destination else {
                throw RenderError.pixelBufferAllocationFailed(status)
            }
            context.render(rendered, to: buffer)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw RenderError.appendFailed
            }
        }
    }

    /// Runs `work` exactly once; subsequent calls are no-ops (end-of-stream can fire twice).
    private func finish(_ work: () -> Void) {
        guard !didFinish else { return }
        didFinish = true
        work()
    }

    /// Applies the crop rect (top-left capture space) as a CoreImage crop + scale.
    ///
    /// CoreImage uses a bottom-left origin, so the top-left rect is flipped in Y before
    /// cropping; the cropped extent is translated back to the origin so the writer receives
    /// an origin-aligned frame, and finally scaled up to the full output size.
    /// `rect` is a platform-free `ZoomTypes.Rect` (top-left origin); CoreGraphics is
    /// introduced only here, at the CoreImage boundary.
    private static func zoom(
        source: CIImage,
        rect: Rect,
        imageHeight: CGFloat,
        outputWidth: CGFloat,
        outputHeight: CGFloat
    ) -> CIImage {
        let flipped = CGRect(
            x: CGFloat(rect.minX),
            y: imageHeight - CGFloat(rect.maxY),
            width: CGFloat(rect.width),
            height: CGFloat(rect.height)
        )
        let cropRect = flipped.intersection(source.extent)
        guard !cropRect.isNull, cropRect.width > 0, cropRect.height > 0 else {
            return source
        }
        let cropped = source
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        let scale = CGAffineTransform(scaleX: outputWidth / cropRect.width, y: outputHeight / cropRect.height)
        return cropped.transformed(by: scale)
    }

    /// Picks the keyframe whose time is nearest the frame's presentation timestamp.
    private static func nearestKeyframe(_ keyframes: [CropKeyframe], pts: Double, fps: Double) -> CropKeyframe? {
        guard !keyframes.isEmpty else { return nil }
        let position = pts.isFinite ? pts : 0
        let index = Int((position * fps).rounded())
        return keyframes[min(max(0, index), keyframes.count - 1)]
    }

    /// Picks the cursor frame nearest the frame's PTS — same indexing as ``nearestKeyframe``.
    /// The outer array is non-nil here (checked by the caller); the inner value may be `nil`
    /// when the pointer is hidden on that frame.
    private static func nearestCursor(_ frames: [CursorFrame?], pts: Double, fps: Double) -> CursorFrame? {
        guard !frames.isEmpty else { return nil }
        let position = pts.isFinite ? pts : 0
        let index = Int((position * fps).rounded())
        return frames[min(max(0, index), frames.count - 1)]
    }
}
