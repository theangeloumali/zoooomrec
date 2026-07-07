import CoreGraphics
import Foundation
import ZoomTypes

#if canImport(ApplicationServices)
  import ApplicationServices
#endif

/// E2EDemo — a small driver executable that makes the zoooomrec end-to-end demo
/// self-contained:
///  - `drive`   generates on-screen cursor activity + clicks while the recorder runs;
///  - `patch`   guarantees the captured event stream has enough clicks to trigger auto-zoom;
///  - `hotkeys` posts REAL ⌃⌥Z / ⌃⌥X keystrokes mid-recording to exercise the LIVE manual-zoom path;
///  - `stoptest` posts a single ⌃⌥S keystroke to exercise the LIVE stop hotkey.
let usage = """
  E2EDemo — end-to-end demo driver for zoooomrec

  USAGE:
    E2EDemo drive --seconds <N>
    E2EDemo patch <bundle.zoooomrec> --min-clicks <N>
    E2EDemo hotkeys --seconds <N>
    E2EDemo stoptest
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
case "hotkeys":
  Hotkeys.run(rest)
case "stoptest":
  StopTest.run(rest)
case "--help", "-h", "help":
  print(usage)
default:
  FileHandle.standardError.write(Data("E2EDemo: unknown subcommand '\(subcommand)'\n\(usage)\n".utf8))
  exit(2)
}

// MARK: - Shared synthetic-input helpers

/// True only when this process may post `CGEvent`s (Accessibility trust). Every
/// active-mode subcommand degrades to a passive sleep when this is false, so the
/// driver never crashes on an untrusted machine.
func accessibilityTrusted() -> Bool {
  #if canImport(ApplicationServices)
    return AXIsProcessTrusted()
  #else
    return false
  #endif
}

/// The main display's geometry with desktop-safe insets. All synthetic activity is
/// clamped to `CGDisplayBounds(CGMainDisplayID())` so nothing lands on a secondary
/// display (which can sit at a negative global x and confuse capture-space coords).
struct DisplayGeometry {
  let bounds: CGRect

  init() { bounds = CGDisplayBounds(CGMainDisplayID()) }

  var width: CGFloat { bounds.width }
  var height: CGFloat { bounds.height }

  // Keep clear of the menu bar (top ~40pt) and dock (~140pt).
  private var sideInset: CGFloat { max(80, bounds.width * 0.12) }
  private var topSafe: CGFloat { bounds.minY + 60 }
  private var bottomSafe: CGFloat { bounds.maxY - 140 }

  func clampX(_ x: CGFloat) -> CGFloat { min(max(bounds.minX + sideInset, x), bounds.maxX - sideInset) }
  func clampY(_ y: CGFloat) -> CGFloat { min(max(topSafe, y), bottomSafe) }

  /// A safe on-screen point at fractional `(fx, fy)` of the main display.
  func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
    CGPoint(x: clampX(bounds.minX + width * fx), y: clampY(bounds.minY + height * fy))
  }
}

/// Posts synthetic mouse + keyboard `CGEvent`s to the HID event tap.
enum SyntheticInput {
  static let source = CGEventSource(stateID: .hidSystemState)

  static func move(to p: CGPoint) {
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
      .post(tap: .cghidEventTap)
  }

  static func click(at p: CGPoint) {
    move(to: p)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?
      .post(tap: .cghidEventTap)
    usleep(30_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?
      .post(tap: .cghidEventTap)
  }

  /// Posts a chorded key press. Modifier flags MUST live on the keyDown event —
  /// the recorder's tap reads `event.flags` on keyDown to detect the ⌃⌥ chord.
  static func key(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(30_000)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
  }
}

/// The zoooomrec live hotkeys (ANSI keycodes) and their ⌃⌥ modifier chord.
enum Hotkey {
  static let zoomIn: CGKeyCode = 6  // Z → open a manual zoom
  static let zoomOut: CGKeyCode = 7  // X → close the active zoom
  static let stop: CGKeyCode = 1  // S → stop the recording
  static let chord: CGEventFlags = [.maskControl, .maskAlternate]
}

/// A piecewise-linear cursor path over synthetic time.
struct Glide {
  let keyframes: [(time: Double, point: CGPoint)]

  func position(at elapsed: Double) -> CGPoint {
    guard let first = keyframes.first, let last = keyframes.last else { return .zero }
    if elapsed <= first.time { return first.point }
    if elapsed >= last.time { return last.point }
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
    return last.point
  }
}

/// A one-shot action fired once when synthetic time first reaches `time`.
struct TimedAction {
  let time: Double
  let action: () -> Void
}

/// Drives a `Glide` from t=0 to `seconds`, posting cursor moves at ~60 Hz and firing
/// each `TimedAction` exactly once as its scheduled time passes. Shared by `drive`
/// (clicks) and `hotkeys` (key posts).
enum SyntheticActivity {
  static func run(glide: Glide, seconds: Double, actions: [TimedAction]) {
    let scheduled = actions.sorted { $0.time < $1.time }
    let start = Date()
    var next = 0
    while true {
      let elapsed = Date().timeIntervalSince(start)
      if elapsed >= seconds { break }
      SyntheticInput.move(to: glide.position(at: elapsed))
      while next < scheduled.count, elapsed >= scheduled[next].time {
        scheduled[next].action()
        next += 1
      }
      usleep(16_000)  // ~60 Hz
    }
    // Fire any actions scheduled at/after the end so their side effects still land.
    while next < scheduled.count {
      scheduled[next].action()
      next += 1
    }
  }
}

/// Parses `--seconds <N>` (default 10) from `args`, exiting 2 on malformed input.
func parseSeconds(_ args: [String], command: String, defaultValue: Double = 10.0) -> Double {
  var seconds = defaultValue
  var index = 0
  while index < args.count {
    switch args[index] {
    case "--seconds", "-s":
      guard index + 1 < args.count, let value = Double(args[index + 1]) else {
        FileHandle.standardError.write(Data("\(command): --seconds requires a number\n".utf8))
        exit(2)
      }
      seconds = value
      index += 2
    default:
      FileHandle.standardError.write(Data("\(command): unknown option '\(args[index])'\n".utf8))
      exit(2)
    }
  }
  guard seconds > 0 else {
    FileHandle.standardError.write(Data("\(command): --seconds must be > 0\n".utf8))
    exit(2)
  }
  return seconds
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
    let seconds = parseSeconds(args, command: "drive")

    guard accessibilityTrusted() else {
      print("drive: not accessibility-trusted, passive mode")
      Thread.sleep(forTimeInterval: seconds)
      return
    }

    driveActive(seconds: seconds)
  }

  /// Posts real cursor moves + clicks constrained to the main display's safe area.
  private static func driveActive(seconds: Double) {
    let geometry = DisplayGeometry()
    let center = geometry.point(0.5, 0.5)
    let target1 = geometry.point(0.25, 0.40)
    let target2 = geometry.point(0.55, 0.58)
    let target3 = geometry.point(0.75, 0.40)
    let clickTimes = [seconds * 0.25, seconds * 0.5, seconds * 0.75]
    let clickPoints = [target1, target2, target3]

    // Piecewise-linear glide path with a ~0.5 s hover before each click.
    let glide = Glide(keyframes: [
      (0, center),
      (max(0.1, clickTimes[0] - 0.5), target1), (clickTimes[0], target1),
      (max(clickTimes[0], clickTimes[1] - 0.5), target2), (clickTimes[1], target2),
      (max(clickTimes[1], clickTimes[2] - 0.5), target3), (clickTimes[2], target3),
      (seconds, center),
    ])

    var clicksPosted = 0
    let actions = zip(clickTimes, clickPoints).map { time, point in
      TimedAction(time: time) {
        SyntheticInput.click(at: point)
        clicksPosted += 1
      }
    }
    SyntheticActivity.run(glide: glide, seconds: seconds, actions: actions)
    print("drive: active mode complete — glided cursor + posted \(clicksPosted) clicks on the main display")
  }
}

// MARK: - hotkeys

/// Posts REAL ⌃⌥Z / ⌃⌥X keystrokes during a live recording to exercise the manual
/// hotkey-zoom path end-to-end. On the MAIN display only:
///  - glides the cursor to screen-center over ~1 s and holds it there,
///  - posts ⌃⌥Z (zoom-in) at ~t=3 s while the cursor is centered,
///  - drifts the cursor to a different area over the next few seconds (so the
///    renderer's cursor-follow has a path to track),
///  - posts ⌃⌥X (zoom-out) at ~t=7 s, then sleeps out the remaining time so the
///    zoom has room to spring back to the full frame before the recording ends.
///
/// Requires Accessibility trust. If untrusted it prints a passive notice and sleeps.
enum Hotkeys {
  static func run(_ args: [String]) {
    let seconds = parseSeconds(args, command: "hotkeys")

    guard accessibilityTrusted() else {
      print("hotkeys: not accessibility-trusted, passive")
      Thread.sleep(forTimeInterval: seconds)
      return
    }

    let geometry = DisplayGeometry()
    let approach = geometry.point(0.42, 0.55)
    let center = geometry.point(0.5, 0.5)
    let away = geometry.point(0.72, 0.62)

    // Timeline relative to this driver's clock (clamped for short --seconds runs).
    let zoomInAt = min(3.0, seconds * 0.3)
    let zoomOutAt = min(7.0, seconds * 0.7)

    let glide = Glide(keyframes: [
      (0, approach),
      (1.0, center),  // ~1 s glide to center
      (zoomInAt, center),  // hold center through the zoom-in
      (zoomOutAt, away),  // drift across the hold so cursor-follow pans
      (seconds, away),
    ])

    let actions = [
      TimedAction(time: zoomInAt) { SyntheticInput.key(Hotkey.zoomIn, flags: Hotkey.chord) },
      TimedAction(time: zoomOutAt) { SyntheticInput.key(Hotkey.zoomOut, flags: Hotkey.chord) },
    ]

    SyntheticActivity.run(glide: glide, seconds: seconds, actions: actions)
    print(
      String(
        format:
          "hotkeys: posted ⌃⌥Z @ %.1fs + ⌃⌥X @ %.1fs, glided cursor on the main display (%.0fs total)",
        zoomInAt, zoomOutAt, seconds))
  }
}

// MARK: - stoptest

/// Posts a single ⌃⌥S keystroke to trigger the recorder's live stop hotkey.
/// Requires Accessibility trust; prints a passive notice and no-ops when untrusted
/// (the harness falls back to SIGINT to stop the recorder).
enum StopTest {
  static func run(_ args: [String]) {
    guard accessibilityTrusted() else {
      print("stoptest: not accessibility-trusted, passive (no ⌃⌥S posted)")
      return
    }
    SyntheticInput.key(Hotkey.stop, flags: Hotkey.chord)
    print("stoptest: posted ⌃⌥S (stop hotkey) on the main display")
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
