import CoreGraphics
import Foundation
import ZoomTypes

#if canImport(ApplicationServices)
  import ApplicationServices
#endif

/// E2EDemo — a small driver executable that makes the zoooomrec end-to-end demo
/// self-contained: `drive` generates on-screen activity while the recorder runs,
/// and `patch` guarantees the captured event stream has enough clicks to trigger
/// an auto-zoom (injecting synthetic clicks when the environment blocks real ones).
let usage = """
  E2EDemo — end-to-end demo driver for zoooomrec

  USAGE:
    E2EDemo drive --seconds <N>
    E2EDemo patch <bundle.zoooomrec> --min-clicks <N>
  """

let arguments = Array(CommandLine.arguments.dropFirst())
guard let subcommand = arguments.first else {
  FileHandle.standardError.write(Data("\(usage)\n".utf8))
  exit(2)
}
let rest = Array(arguments.dropFirst())

switch subcommand {
case "drive":
  Driver.run(rest)
case "patch":
  do {
    try Patcher.run(rest)
  } catch {
    FileHandle.standardError.write(Data("patch: error: \(error)\n".utf8))
    exit(1)
  }
case "--help", "-h", "help":
  print(usage)
default:
  FileHandle.standardError.write(Data("E2EDemo: unknown subcommand '\(subcommand)'\n\(usage)\n".utf8))
  exit(2)
}

// MARK: - drive

/// Generates on-screen activity for `--seconds N` on the MAIN display only:
/// glides the cursor between a few desktop-safe waypoints at ~60 Hz and left-clicks
/// at 25% / 50% / 75% of the timeline (hovering ~0.5 s before each click).
///
/// Requires Accessibility trust to post `CGEvent`s. If untrusted it degrades to a
/// passive mode that simply sleeps the timeline — the recorder still captures
/// whatever is on screen, and `patch` supplies the clicks afterward.
enum Driver {
  static func run(_ args: [String]) {
    var seconds = 10.0
    var index = 0
    while index < args.count {
      switch args[index] {
      case "--seconds", "-s":
        guard index + 1 < args.count, let value = Double(args[index + 1]) else {
          FileHandle.standardError.write(Data("drive: --seconds requires a number\n".utf8))
          exit(2)
        }
        seconds = value
        index += 2
      default:
        FileHandle.standardError.write(Data("drive: unknown option '\(args[index])'\n".utf8))
        exit(2)
      }
    }
    guard seconds > 0 else {
      FileHandle.standardError.write(Data("drive: --seconds must be > 0\n".utf8))
      exit(2)
    }

    #if canImport(ApplicationServices)
      let trusted = AXIsProcessTrusted()
    #else
      let trusted = false
    #endif

    guard trusted else {
      print("drive: not accessibility-trusted, passive mode")
      Thread.sleep(forTimeInterval: seconds)
      return
    }

    driveActive(seconds: seconds)
  }

  /// Posts real cursor moves + clicks constrained to the main display's safe area.
  private static func driveActive(seconds: Double) {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let width = bounds.width
    let height = bounds.height
    // Desktop-safe insets: keep clear of the menu bar (top ~40pt) and dock (~120pt).
    let sideInset = max(80, width * 0.12)
    let topSafe = max(bounds.minY + 60, bounds.minY + 40)
    let bottomSafe = bounds.maxY - 140

    func clampX(_ x: CGFloat) -> CGFloat { min(max(bounds.minX + sideInset, x), bounds.maxX - sideInset) }
    func clampY(_ y: CGFloat) -> CGFloat { min(max(topSafe, y), bottomSafe) }
    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
      CGPoint(x: clampX(bounds.minX + width * fx), y: clampY(bounds.minY + height * fy))
    }

    let center = point(0.5, 0.5)
    let target1 = point(0.25, 0.40)
    let target2 = point(0.55, 0.58)
    let target3 = point(0.75, 0.40)
    let clickTimes = [seconds * 0.25, seconds * 0.5, seconds * 0.75]
    let clickPoints = [target1, target2, target3]

    // Piecewise-linear glide path with a ~0.5 s hover before each click.
    let keyframes: [(time: Double, point: CGPoint)] = [
      (0, center),
      (max(0.1, clickTimes[0] - 0.5), target1), (clickTimes[0], target1),
      (max(clickTimes[0], clickTimes[1] - 0.5), target2), (clickTimes[1], target2),
      (max(clickTimes[1], clickTimes[2] - 0.5), target3), (clickTimes[2], target3),
      (seconds, center),
    ]

    let source = CGEventSource(stateID: .hidSystemState)

    func position(at elapsed: Double) -> CGPoint {
      if elapsed <= keyframes.first!.time { return keyframes.first!.point }
      if elapsed >= keyframes.last!.time { return keyframes.last!.point }
      for k in 1..<keyframes.count {
        let previous = keyframes[k - 1]
        let next = keyframes[k]
        if elapsed <= next.time {
          let span = max(0.0001, next.time - previous.time)
          let fraction = CGFloat((elapsed - previous.time) / span)
          return CGPoint(
            x: previous.point.x + (next.point.x - previous.point.x) * fraction,
            y: previous.point.y + (next.point.y - previous.point.y) * fraction
          )
        }
      }
      return keyframes.last!.point
    }

    func postMove(_ p: CGPoint) {
      CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    }
    func postClick(_ p: CGPoint) {
      postMove(p)
      CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
      usleep(30_000)
      CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    }

    let start = Date()
    var nextClick = 0
    while true {
      let elapsed = Date().timeIntervalSince(start)
      if elapsed >= seconds { break }
      postMove(position(at: elapsed))
      if nextClick < clickTimes.count, elapsed >= clickTimes[nextClick] {
        postClick(clickPoints[nextClick])
        nextClick += 1
      }
      usleep(16_000)  // ~60 Hz
    }
    print("drive: active mode complete — glided cursor + posted \(nextClick) clicks on the main display")
  }
}

// MARK: - patch

/// Reads a bundle's `events.jsonl`, and if it has fewer than `--min-clicks`
/// real clicks, injects synthetic `left_click` events at 25% / 50% / 75% of the
/// manifest duration so the renderer's auto-zoom fires. Injected click positions
/// reuse the nearest-in-time captured move (so the zoom follows the real cursor
/// path); with no moves it falls back to spread positions inside the pixel frame.
enum Patcher {
  enum PatchError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
      switch self {
      case .usage(let message): return message
      }
    }
  }

  static func run(_ args: [String]) throws {
    var bundlePath: String?
    var minClicks = 3
    var index = 0
    while index < args.count {
      switch args[index] {
      case "--min-clicks":
        guard index + 1 < args.count, let value = Int(args[index + 1]) else {
          throw PatchError.usage("patch: --min-clicks requires an integer")
        }
        minClicks = value
        index += 2
      default:
        guard bundlePath == nil else {
          throw PatchError.usage("patch: unexpected argument '\(args[index])'")
        }
        bundlePath = args[index]
        index += 1
      }
    }
    guard let bundlePath else {
      throw PatchError.usage("patch: <bundle.zoooomrec> path is required")
    }

    let bundle = URL(fileURLWithPath: bundlePath)
    let manifestURL = bundle.appendingPathComponent(ZoooomrecBundle.manifestName)
    let manifest = try JSONDecoder().decode(
      ProjectManifest.self, from: Data(contentsOf: manifestURL))
    let eventsURL = bundle.appendingPathComponent(manifest.eventsFile)

    var events = readEvents(eventsURL)
    let clickCount = events.filter { $0.kind == .leftClick || $0.kind == .rightClick }.count

    if clickCount >= minClicks {
      print("patch: \(clickCount) real clicks, no injection")
      return
    }

    // events.jsonl coordinates are already capture-space pixels — reuse them directly.
    let moves = events.filter { $0.kind == .move }
    let duration = manifest.durationSeconds
    let width = Double(manifest.pixelWidth)
    let height = Double(manifest.pixelHeight)

    var injected: [InputEvent] = []
    for fraction in [0.25, 0.5, 0.75] {
      let time = duration * fraction
      let x: Double
      let y: Double
      if let nearest = moves.min(by: { abs($0.t - time) < abs($1.t - time) }) {
        x = nearest.x
        y = nearest.y
      } else {
        x = width * fraction
        y = height * 0.5
      }
      injected.append(InputEvent(t: time, kind: .leftClick, x: x, y: y))
    }

    events.append(contentsOf: injected)
    events.sort { $0.t < $1.t }
    try writeEvents(events, to: eventsURL)

    let description = injected
      .map { String(format: "t=%.2fs @ (%.0f, %.0f)", $0.t, $0.x, $0.y) }
      .joined(separator: ", ")
    let basis = moves.isEmpty ? "spread fallback (no move events)" : "nearest captured move"
    print("patch: \(clickCount) real clicks (< \(minClicks)) — injecting \(injected.count) left_clicks via \(basis)")
    print("patch: injected \(description)")
    print("patch: rewrote \(events.count) time-sorted events → \(eventsURL.path)")
  }

  /// Parses newline-delimited JSON events; tolerates a missing or empty file.
  private static func readEvents(_ url: URL) -> [InputEvent] {
    guard let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    let decoder = JSONDecoder()
    var result: [InputEvent] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty,
        let lineData = trimmed.data(using: .utf8),
        let event = try? decoder.decode(InputEvent.self, from: lineData)
      else { continue }
      result.append(event)
    }
    return result
  }

  private static func writeEvents(_ events: [InputEvent], to url: URL) throws {
    let encoder = JSONEncoder()
    var text = ""
    for event in events {
      let data = try encoder.encode(event)
      text += String(decoding: data, as: UTF8.self)
      text += "\n"
    }
    try text.write(to: url, atomically: true, encoding: .utf8)
  }
}
