import CoreGraphics
import CoreMedia
import Foundation
import ZoomTypes

/// C-compatible callback for the listen-only click tap. Must not capture context;
/// the `EventRecorder` is passed back through `userInfo`.
private func eventTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let recorder = Unmanaged<EventRecorder>.fromOpaque(userInfo).takeUnretainedValue()
  switch type {
  case .leftMouseDown:
    recorder.recordClick(.leftClick, at: event.location)
  case .rightMouseDown:
    recorder.recordClick(.rightClick, at: event.location)
  case .keyDown:
    recorder.handleKeyDown(event)
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    recorder.reEnableTap()
  default:
    break
  }
  // Listen-only tap: always pass every event through unmodified so the user's
  // other apps still receive the keystrokes/clicks.
  return Unmanaged.passUnretained(event)
}

/// Captures the global cursor stream during a recording.
///
/// - Cursor *moves* are polled at 60 Hz via `CGEvent(source: nil)?.location`, which
///   requires no TCC permission.
/// - Left/right *clicks* come from a listen-only `CGEventTap`. If the tap cannot be
///   created (missing Input Monitoring permission) the recorder logs one warning and
///   continues with moves only — it never crashes.
///
/// Timestamps are stored as raw host-clock seconds and aligned to the first video
/// frame's presentation time later by `ScreenRecorder`.
final class EventRecorder {
  struct RawEvent {
    let host: Double
    let kind: InputEvent.Kind
    let x: Double
    let y: Double
  }

  /// Invoked (on the tap's runloop thread) when the stop hotkey ⌃⌥S is pressed.
  /// Simple stored closure — the owner races this against the duration timer.
  var onStop: (() -> Void)?

  private let scaleFactor: Double
  private let lock = NSLock()
  private var events: [RawEvent] = []

  private let moveQueue = DispatchQueue(label: "zoooomrec.events.move")
  private var moveTimer: DispatchSourceTimer?

  private var tapThread: Thread?
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var tapRunLoop: CFRunLoop?

  init(scaleFactor: Double) {
    self.scaleFactor = scaleFactor
  }

  func start() {
    startMovePolling()
    startClickTap()
  }

  /// Stops all monitors and returns the captured events (host-clock timestamps).
  func stop() -> [RawEvent] {
    moveTimer?.cancel()
    moveTimer = nil
    stopClickTap()
    lock.lock()
    let snapshot = events
    lock.unlock()
    return snapshot
  }

  // MARK: - Recording

  private func hostSeconds() -> Double {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
  }

  private func append(_ kind: InputEvent.Kind, at location: CGPoint) {
    let event = RawEvent(
      host: hostSeconds(),
      kind: kind,
      x: Double(location.x) * scaleFactor,
      y: Double(location.y) * scaleFactor
    )
    lock.lock()
    events.append(event)
    lock.unlock()
  }

  /// Invoked from the C tap callback.
  func recordClick(_ kind: InputEvent.Kind, at location: CGPoint) {
    append(kind, at: location)
  }

  /// Invoked from the C tap callback for every key-down. Only ⌃⌥-chorded ANSI
  /// Z / X / S carry meaning; everything else passes through untouched.
  func handleKeyDown(_ event: CGEvent) {
    let flags = event.flags
    guard flags.contains(.maskControl), flags.contains(.maskAlternate) else { return }
    switch event.getIntegerValueField(.keyboardEventKeycode) {
    case 6:  // ANSI Z → open a manual zoom at the cursor
      recordHotkeyZoom(.zoomIn)
    case 7:  // ANSI X → close the active zoom
      recordHotkeyZoom(.zoomOut)
    case 1:  // ANSI S → stop the recording (no event appended)
      onStop?()
    default:
      break
    }
  }

  /// Appends a live zoom marker at the current cursor position, using the same
  /// capture-space (scaleFactor) conversion applied to clicks.
  private func recordHotkeyZoom(_ kind: InputEvent.Kind) {
    let location = CGEvent(source: nil)?.location ?? .zero
    append(kind, at: location)
  }

  /// Re-enables the tap after the system disables it (timeout / user input).
  func reEnableTap() {
    guard let eventTap else { return }
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  // MARK: - Move polling (no permission required)

  private func startMovePolling() {
    let timer = DispatchSource.makeTimerSource(queue: moveQueue)
    timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 60))
    timer.setEventHandler { [weak self] in
      guard let self, let location = CGEvent(source: nil)?.location else { return }
      self.append(.move, at: location)
    }
    timer.resume()
    moveTimer = timer
  }

  // MARK: - Click tap (needs Input Monitoring; degrades gracefully)

  private func startClickTap() {
    let mask =
      (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
      | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
      | (CGEventMask(1) << CGEventType.keyDown.rawValue)
    let selfPointer = Unmanaged.passUnretained(self).toOpaque()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: eventTapCallback,
        userInfo: selfPointer
      )
    else {
      FileHandle.standardError.write(
        Data(
          "warning: could not create input event tap (grant Accessibility under System Settings → Privacy & Security so clicks and ⌃⌥ hotkey zoom markers are captured); continuing with cursor moves only\n"
            .utf8
        ))
      return
    }
    eventTap = tap

    let thread = Thread { [weak self] in
      guard let self, let eventTap = self.eventTap else { return }
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
      self.runLoopSource = source
      self.tapRunLoop = CFRunLoopGetCurrent()
      CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
      CGEvent.tapEnable(tap: eventTap, enable: true)
      CFRunLoopRun()
    }
    thread.name = "zoooomrec.events.tap"
    thread.start()
    tapThread = thread
  }

  private func stopClickTap() {
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }
    if let tapRunLoop, let runLoopSource {
      CFRunLoopRemoveSource(tapRunLoop, runLoopSource, .commonModes)
    }
    if let tapRunLoop {
      CFRunLoopStop(tapRunLoop)
    }
    if let eventTap {
      CFMachPortInvalidate(eventTap)
    }
    eventTap = nil
    runLoopSource = nil
    tapRunLoop = nil
    tapThread = nil
  }
}
