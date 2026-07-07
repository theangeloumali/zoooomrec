import AVFoundation
import CoreGraphics
import Foundation

/// Builds a deterministic H.264 test clip programmatically (no committed binaries):
/// a dark-gray background with a bright square whose x position sweeps left→right.
struct SyntheticClip {
    let width: Int
    let height: Int
    let fps: Int
    let durationSeconds: Double

    let margin = 20
    let squareSize = 40

    var frameCount: Int { Int((durationSeconds * Double(fps)).rounded()) }
    private var travel: Double { Double(width - squareSize - 2 * margin) }

    /// The horizontal center of the bright square at a given time, in top-left pixels.
    func squareCenterX(atTime time: Double) -> Double {
        let index = min(max(0, Int((time * Double(fps)).rounded())), frameCount - 1)
        let fraction = frameCount > 1 ? Double(index) / Double(frameCount - 1) : 0
        return Double(margin) + fraction * travel + Double(squareSize) / 2
    }

    func write(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
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
        guard writer.canAdd(input) else { throw fixtureError("cannot add writer input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? fixtureError("startWriting failed") }
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 500_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw fixtureError("no pixel-buffer pool") }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let buffer = pixelBuffer else {
                throw fixtureError("pixel-buffer allocation failed")
            }
            draw(frame: index, into: buffer, colorSpace: colorSpace)
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? fixtureError("append failed")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status == .failed {
            throw writer.error ?? fixtureError("writer finished in failed state")
        }
    }

    private func draw(frame index: Int, into buffer: CVPixelBuffer, colorSpace: CGColorSpace) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        context.setFillColor(red: 30.0 / 255, green: 30.0 / 255, blue: 30.0 / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let fraction = frameCount > 1 ? Double(index) / Double(frameCount - 1) : 0
        let x = Double(margin) + fraction * travel
        let y = Double(height) / 2 - Double(squareSize) / 2
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: x, y: y, width: Double(squareSize), height: Double(squareSize)))
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "zoooomrec.test.fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
