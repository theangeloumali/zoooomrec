import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import ZoomTypes

/// NSError domain ScreenCaptureKit uses for stream/content failures.
private let screenCaptureKitErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"

/// Records the main display into a `.zoooomrec` bundle: H.264 video (native pixel
/// resolution, no burned-in cursor, 60 fps), an `events.jsonl` cursor stream, and a
/// `project.json` manifest. See the CaptureEngine packet contract for details.
public final class ScreenRecorder {
  /// Frames written by the most recent `record(...)` call (for CLI reporting).
  public private(set) var lastFrameCount: Int = 0
  /// Events written by the most recent `record(...)` call (for CLI reporting).
  public private(set) var lastEventCount: Int = 0

  // Stop-signal plumbing. `requestStop()`, the duration timer, and the stop
  // hotkey all funnel through `signalStop()`, which resumes the wait
  // continuation at most once. `stopLock` guards every access so the signal is
  // safe to fire from ANY thread (SIGINT queue, timer queue, tap runloop).
  private let stopLock = NSLock()
  private var stopContinuation: CheckedContinuation<Void, Never>?
  private var stopRequested = false
  private let stopTimerQueue = DispatchQueue(label: "zoooomrec.capture.stop")

  public init() {}

  /// Ends the current recording early. Idempotent and thread-safe — safe to call
  /// from a signal handler, a timer, or the event-tap thread.
  public func requestStop() {
    signalStop()
  }

  /// Clears stop state at the start of a recording so the instance is reusable.
  private func resetStopState() {
    stopLock.lock()
    stopRequested = false
    stopContinuation = nil
    stopLock.unlock()
  }

  /// Resumes the wait continuation exactly once, regardless of how many stop
  /// triggers fire or in what order they race the continuation being parked.
  private func signalStop() {
    stopLock.lock()
    if stopRequested {
      stopLock.unlock()
      return
    }
    stopRequested = true
    let continuation = stopContinuation
    stopContinuation = nil
    stopLock.unlock()
    continuation?.resume()
  }

  /// Parks until the first stop trigger fires. If a trigger already fired before
  /// we park, resumes immediately so no signal is ever lost.
  private func waitForStop() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      stopLock.lock()
      if stopRequested {
        stopLock.unlock()
        continuation.resume()
      } else {
        stopContinuation = continuation
        stopLock.unlock()
      }
    }
  }

  public func record(
    durationSeconds: Double?,
    zoomScale: Double,
    to bundleURL: URL
  ) async throws -> ProjectManifest {
    resetStopState()

    let fileManager = FileManager.default
    try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let videoURL = bundleURL.appendingPathComponent(ZoooomrecBundle.videoName)
    let eventsURL = bundleURL.appendingPathComponent(ZoooomrecBundle.eventsName)
    let manifestURL = bundleURL.appendingPathComponent(ZoooomrecBundle.manifestName)
    try? fileManager.removeItem(at: videoURL)

    let display = try await mainDisplay()
    let scaleFactor = displayScaleFactor(for: display)
    let pixelWidth = Int((Double(display.width) * scaleFactor).rounded())
    let pixelHeight = Int((Double(display.height) * scaleFactor).rounded())

    let (writer, videoInput, adaptor) = try makeWriter(
      url: videoURL,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
    guard writer.startWriting() else {
      throw CaptureError.assetWriterFailed(
        writer.error?.localizedDescription ?? "startWriting returned false")
    }

    let configuration = makeConfiguration(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let handler = StreamOutputHandler(writer: writer, videoInput: videoInput, adaptor: adaptor)
    let stream = SCStream(filter: filter, configuration: configuration, delegate: handler)
    let sampleQueue = DispatchQueue(label: "zoooomrec.capture.samples")
    try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: sampleQueue)

    let eventRecorder = EventRecorder(scaleFactor: scaleFactor)
    eventRecorder.onStop = { [weak self] in self?.signalStop() }  // stop hotkey ⌃⌥S
    eventRecorder.start()
    try await stream.startCapture()

    // Race three first-wins stop triggers: (a) the optional duration timer,
    // (b) the stop hotkey (via onStop), (c) an external requestStop() call.
    let durationTimer: DispatchSourceTimer?
    if let durationSeconds {
      let timer = DispatchSource.makeTimerSource(queue: stopTimerQueue)
      timer.schedule(deadline: .now() + durationSeconds)
      timer.setEventHandler { [weak self] in self?.signalStop() }
      timer.resume()
      durationTimer = timer
    } else {
      durationTimer = nil
    }
    await waitForStop()
    durationTimer?.cancel()

    try await stream.stopCapture()
    sampleQueue.sync {}  // drain any in-flight sample blocks before reading counts

    let rawEvents = eventRecorder.stop()

    videoInput.markAsFinished()
    await finishWriting(writer)
    if writer.status == .failed {
      throw CaptureError.assetWriterFailed(
        writer.error?.localizedDescription ?? "unknown writer error")
    }

    let anchor = handler.firstPTS?.seconds
    let inputEvents = alignEvents(rawEvents, toFirstFrame: anchor)
    try writeEvents(inputEvents, to: eventsURL)

    let actualDuration: Double
    if let first = handler.firstPTS, let last = handler.lastPTS {
      actualDuration = max(0, (last - first).seconds)
    } else {
      actualDuration = 0
    }

    // ZR-101: a v2 bundle carries the cursor as `move` events only, so the
    // manifest MUST record cursorBurnedIn: false in lockstep with the
    // showsCursor = false above. Writing one without the other yields an
    // inconsistent bundle (a v2 that resolves to burned-in via the nil default).
    let manifest = ProjectManifest(
      version: ZoooomrecBundle.currentVersion,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      fps: 60,
      durationSeconds: actualDuration,
      segments: nil,
      zoomScale: zoomScale,
      cursorBurnedIn: false
    )
    try encodeManifest(manifest).write(to: manifestURL)

    lastFrameCount = handler.frameCount
    lastEventCount = inputEvents.count
    return manifest
  }

  // MARK: - ScreenCaptureKit setup

  private func mainDisplay() async throws -> SCDisplay {
    let content: SCShareableContent
    do {
      content = try await shareableContent()
    } catch {
      let nsError = error as NSError
      if nsError.domain == screenCaptureKitErrorDomain,
        nsError.code == SCStreamError.Code.userDeclined.rawValue
      {
        throw CaptureError.screenRecordingPermissionDenied
      }
      throw error
    }

    guard
      let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        ?? content.displays.first
    else {
      throw CaptureError.noDisplayAvailable
    }
    return display
  }

  private func shareableContent() async throws -> SCShareableContent {
    try await withCheckedThrowingContinuation { continuation in
      SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
        content, error in
        if let content {
          continuation.resume(returning: content)
        } else {
          continuation.resume(throwing: error ?? CaptureError.noDisplayAvailable)
        }
      }
    }
  }

  private func displayScaleFactor(for display: SCDisplay) -> Double {
    let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
    let matching = NSScreen.screens.first { screen in
      (screen.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value == display.displayID
    }
    return Double(matching?.backingScaleFactor ?? 2.0)
  }

  private func makeConfiguration(pixelWidth: Int, pixelHeight: Int) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = pixelWidth
    configuration.height = pixelHeight
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    // ZR-101: keep the real macOS pointer OUT of recording.mp4. The cursor is
    // reconstructed at render time from the 60 Hz `move` event track, which is
    // exactly what lets us smooth, resize, and hide-when-static it — none of
    // which is possible once the pointer is baked into the captured pixels.
    configuration.showsCursor = false
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.queueDepth = 6
    return configuration
  }

  // MARK: - AVAssetWriter setup

  private func makeWriter(
    url: URL,
    pixelWidth: Int,
    pixelHeight: Int
  ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: pixelWidth,
      AVVideoHeightKey: pixelHeight,
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = true

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: pixelWidth,
        kCVPixelBufferHeightKey as String: pixelHeight,
      ]
    )

    guard writer.canAdd(videoInput) else {
      throw CaptureError.assetWriterFailed("cannot add video input")
    }
    writer.add(videoInput)
    return (writer, videoInput, adaptor)
  }

  private func finishWriting(_ writer: AVAssetWriter) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting {
        continuation.resume()
      }
    }
  }

  // MARK: - Output serialization

  /// Aligns raw host-clock event timestamps to the first frame's presentation time.
  /// Events before the first frame clamp to `t = 0`; if no frame arrived, all clamp to 0.
  private func alignEvents(_ rawEvents: [EventRecorder.RawEvent], toFirstFrame anchor: Double?)
    -> [InputEvent]
  {
    rawEvents.map { raw in
      let t = anchor.map { max(0, raw.host - $0) } ?? 0
      return InputEvent(t: t, kind: raw.kind, x: raw.x, y: raw.y)
    }
    .sorted { $0.t < $1.t }
  }

  private func writeEvents(_ events: [InputEvent], to url: URL) throws {
    let encoder = JSONEncoder()
    var text = ""
    for event in events {
      let data = try encoder.encode(event)
      text += String(decoding: data, as: UTF8.self)
      text += "\n"
    }
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func encodeManifest(_ manifest: ProjectManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(manifest)
  }
}
