import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Receives `SCStream` screen samples, encodes them to H.264 via the asset-writer
/// pixel-buffer adaptor, and records the first/last presentation times so the event
/// clock can be anchored to the first frame.
final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate {
  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor

  private let lock = NSLock()
  private(set) var firstPTS: CMTime?
  private(set) var lastPTS: CMTime?
  private(set) var frameCount = 0
  private(set) var stopError: Error?

  init(
    writer: AVAssetWriter,
    videoInput: AVAssetWriterInput,
    adaptor: AVAssetWriterInputPixelBufferAdaptor
  ) {
    self.writer = writer
    self.videoInput = videoInput
    self.adaptor = adaptor
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen else { return }
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    guard isFrameComplete(sampleBuffer) else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    lock.lock()
    defer { lock.unlock() }

    if firstPTS == nil {
      firstPTS = pts
      writer.startSession(atSourceTime: pts)
    }
    lastPTS = pts

    guard videoInput.isReadyForMoreMediaData else { return }
    if adaptor.append(pixelBuffer, withPresentationTime: pts) {
      frameCount += 1
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lock.lock()
    stopError = error
    lock.unlock()
  }

  /// ScreenCaptureKit tags each screen sample with a status; only `.complete`
  /// frames carry fresh pixels (idle frames repeat the last image and must be dropped).
  private func isFrameComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false)
        as? [[SCStreamFrameInfo: Any]],
      let info = attachments.first,
      let statusRaw = info[.status] as? Int,
      let status = SCFrameStatus(rawValue: statusRaw)
    else {
      return false
    }
    return status == .complete
  }
}
