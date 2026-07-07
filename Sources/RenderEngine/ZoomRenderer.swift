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

        let segments = bundle.manifest.segments ?? AutoZoom.segments(
            from: bundle.events,
            width: Double(bundle.manifest.pixelWidth),
            height: Double(bundle.manifest.pixelHeight)
        )
        let keyframes = ZoomTimeline.cropKeyframes(
            segments: segments,
            width: Double(pixelWidth),
            height: Double(pixelHeight),
            fps: fps,
            duration: duration.seconds
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

            let rendered: CIImage
            if let keyframe = RenderPipeline.nearestKeyframe(keyframes, pts: pts.seconds, fps: fps) {
                rendered = RenderPipeline.zoom(
                    source: source,
                    rect: keyframe.rect,
                    imageHeight: imageHeight,
                    outputWidth: CGFloat(outputWidth),
                    outputHeight: CGFloat(outputHeight)
                )
            } else {
                rendered = source
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
    private static func zoom(
        source: CIImage,
        rect: CGRect,
        imageHeight: CGFloat,
        outputWidth: CGFloat,
        outputHeight: CGFloat
    ) -> CIImage {
        let flipped = CGRect(
            x: rect.minX,
            y: imageHeight - rect.maxY,
            width: rect.width,
            height: rect.height
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
}
