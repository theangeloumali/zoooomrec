import CaptureEngine
import Foundation

enum RecordCommand {
  static func run(arguments: [String]) async throws {
    var outputPath: String?
    var duration = 10.0

    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--help", "-h":
        print(usageText)
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
      default:
        throw usageError("record: unknown option '\(argument)'")
      }
    }

    guard let outputPath else {
      throw usageError("record: --output <path.zoooomrec> is required")
    }
    guard duration > 0 else {
      throw usageError("record: --duration must be greater than 0")
    }

    let bundleURL = normalizedBundleURL(from: outputPath)
    let recorder = ScreenRecorder()
    do {
      let manifest = try await recorder.record(durationSeconds: duration, to: bundleURL)
      print(
        "Recorded \(recorder.lastFrameCount) frames, \(recorder.lastEventCount) events → \(bundleURL.path)"
      )
      print(
        "  \(manifest.pixelWidth)×\(manifest.pixelHeight) @ \(Int(manifest.fps)) fps, \(String(format: "%.2f", manifest.durationSeconds))s"
      )
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
  }

  private static func value(after index: Int, in arguments: [String], flag: String) throws -> String
  {
    guard index + 1 < arguments.count else {
      throw usageError("record: \(flag) requires a value")
    }
    return arguments[index + 1]
  }

  private static func usageError(_ message: String) -> CLIError {
    CLIError.usage("\(message)\n\n\(usageText)")
  }

  private static func normalizedBundleURL(from path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    let finalPath = expanded.hasSuffix(".zoooomrec") ? expanded : expanded + ".zoooomrec"
    return URL(fileURLWithPath: finalPath)
  }
}
