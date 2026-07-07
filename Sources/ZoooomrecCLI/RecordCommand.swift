import AppKit
import CaptureEngine
import Foundation
import RenderEngine
import ZoomTypes

enum RecordCommand {
  static func run(arguments: [String]) async throws {
    var outputPath: String?
    var duration: Double?
    var zoomScale = ZoomDefaults.scale
    var noRender = false
    var openWhenDone = false

    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--help", "-h":
        print(recordUsage)
        return
      case "--output", "-o":
        outputPath = try value(after: index, in: arguments, flag: "--output")
        index += 2
      case "--duration", "-d":
        let raw = try value(after: index, in: arguments, flag: "--duration")
        guard let parsed = Double(raw) else {
          throw usageError("record: --duration must be a number, got '\(raw)'")
        }
        duration = parsed
        index += 2
      case "--zoom-scale":
        let raw = try value(after: index, in: arguments, flag: "--zoom-scale")
        guard let parsed = Double(raw) else {
          throw usageError("record: --zoom-scale must be a number, got '\(raw)'")
        }
        zoomScale = parsed
        index += 2
      case "--no-render":
        noRender = true
        index += 1
      case "--open":
        openWhenDone = true
        index += 1
      default:
        throw usageError("record: unknown option '\(argument)'")
      }
    }

    guard let outputPath else {
      throw usageError("record: --output <path.zoooomrec> is required")
    }
    if let duration, duration <= 0 {
      throw usageError("record: --duration must be greater than 0")
    }
    guard zoomScale > 0 else {
      throw usageError("record: --zoom-scale must be greater than 0")
    }

    let bundleURL = normalizedBundleURL(from: outputPath)
    let mp4URL = siblingMP4URL(for: bundleURL)
    let recorder = ScreenRecorder()

    // Ctrl+C stops the recording gracefully (then auto-renders) instead of
    // killing the process. Ignore the default handler first, then service SIGINT
    // on a background queue that drives recorder.requestStop().
    signal(SIGINT, SIG_IGN)
    let signalQueue = DispatchQueue(label: "zoooomrec.cli.signal")
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    sigintSource.setEventHandler { recorder.requestStop() }
    sigintSource.resume()
    defer {
      sigintSource.cancel()
      signal(SIGINT, SIG_DFL)  // restore default so Ctrl+C works during/after render
    }

    if duration == nil {
      print("Recording until ⌃⌥S or Ctrl+C… (⌃⌥Z zoom-in · ⌃⌥X zoom-out)")
    }

    let manifest: ProjectManifest
    do {
      manifest = try await recorder.record(
        durationSeconds: duration, zoomScale: zoomScale, to: bundleURL)
    } catch CaptureError.screenRecordingPermissionDenied {
      FileHandle.standardError.write(
        Data(
          """
          error: screen recording permission denied.

          Grant Screen Recording access to this binary, then re-run:
            System Settings → Privacy & Security → Screen Recording

          """.utf8))
      throw CaptureError.screenRecordingPermissionDenied
    }

    print(
      "Recorded \(recorder.lastFrameCount) frames, \(recorder.lastEventCount) events → \(bundleURL.path)"
    )
    print(
      "  \(manifest.pixelWidth)×\(manifest.pixelHeight) @ \(Int(manifest.fps)) fps, \(String(format: "%.2f", manifest.durationSeconds))s"
    )

    guard !noRender else {
      print("  render skipped (--no-render); run: zoooomrec render \(bundleURL.path) --output \(mp4URL.path)")
      return
    }

    print("Rendering zoom video…")
    try await ZoomRenderer().render(projectBundle: bundleURL, outputURL: mp4URL)
    print("Rendered → \(mp4URL.path)")

    if openWhenDone {
      NSWorkspace.shared.open(mp4URL)
    }
  }

  private static func value(after index: Int, in arguments: [String], flag: String) throws -> String
  {
    guard index + 1 < arguments.count else {
      throw usageError("record: \(flag) requires a value")
    }
    return arguments[index + 1]
  }

  private static func usageError(_ message: String) -> CLIError {
    CLIError.usage("\(message)\n\n\(recordUsage)")
  }

  private static func normalizedBundleURL(from path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    let finalPath = expanded.hasSuffix(".zoooomrec") ? expanded : expanded + ".zoooomrec"
    return URL(fileURLWithPath: finalPath)
  }

  /// The sibling MP4 next to the bundle: the `.zoooomrec` suffix replaced by `.mp4`.
  private static func siblingMP4URL(for bundleURL: URL) -> URL {
    let path = bundleURL.path
    let base = path.hasSuffix(".zoooomrec") ? String(path.dropLast(".zoooomrec".count)) : path
    return URL(fileURLWithPath: base + ".mp4")
  }

  private static let recordUsage = """
    zoooomrec record — record the main display to a .zoooomrec bundle, then auto-render an MP4

    USAGE:
      zoooomrec record --output <path.zoooomrec> [options]

    OPTIONS:
      --output, -o <path>    output bundle path (.zoooomrec appended if missing) [required]
      --duration, -d <sec>   fixed length; omit to record until the stop hotkey / Ctrl+C
      --zoom-scale <x>       zoom magnification applied at render (default 2.0)
      --no-render            record only; skip the automatic MP4 render
      --open                 open the rendered MP4 when finished

    HOTKEYS (need Accessibility): ⌃⌥S stop · ⌃⌥Z zoom-in marker · ⌃⌥X zoom-out marker
    """
}
