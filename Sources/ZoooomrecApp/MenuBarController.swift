import AppKit
import CaptureEngine
import Foundation
import RenderEngine
import ZoomTypes

/// Drives the zoooomrec menu-bar app: an `NSStatusItem` + `NSMenu` that starts/stops
/// a recording and picks the zoom scale entirely from the menu bar — no terminal.
///
/// Also the `NSApplicationDelegate`. On quit it refuses to abandon an in-flight take
/// (ZR-904): a `.recording` / `.rendering` pipeline gets `.terminateLater` and the app
/// only replies once the record+render `Task` lands (or a 60s safety timeout fires),
/// so `~/Movies/zoooomrec/rec-N.mp4` is never truncated.
///
/// AppKit rule: `NSStatusItem` / `NSMenu` / `NSApplicationDelegate` callbacks are
/// main-thread only. Menu target-action callbacks and the delegate arrive on the main
/// thread; the background recording `Task` marshals every UI mutation back to the main
/// queue via `DispatchQueue.main.async`.
///
/// `@unchecked Sendable`: every stored property is touched only on the main thread.
/// The recording `Task` reads no state after spawn and reports each phase transition
/// (and throttled render progress) back through `DispatchQueue.main.async`, so the
/// cross-actor capture is safe.
final class MenuBarController: NSObject, NSApplicationDelegate, @unchecked Sendable {
  /// Coarse lifecycle of the single recording pipeline. Only `.idle` may start a
  /// new recording, which is how double-start is prevented.
  private enum State {
    case idle
    case recording
    case rendering
  }

  // Retained AppKit surface (main-thread only).
  private var statusItem: NSStatusItem?
  private let toggleItem = NSMenuItem()
  private let statusLineItem = NSMenuItem()
  private let warningLineItem = NSMenuItem()
  private let revealItem = NSMenuItem()
  private let openItem = NSMenuItem()
  private let editItem = NSMenuItem()
  private let permissionsItem = NSMenuItem()
  private var zoomItems: [NSMenuItem] = []

  // Recording state (mutated on the main thread only).
  private var state: State = .idle
  private var statusLineText = "Idle"
  private var selectedScale = ZoomDefaults.scale
  private var lastRenderedMP4: URL?
  private var lastBundleURL: URL?
  private var activeRecorder: ScreenRecorder?

  /// Live recording clock. A main-queue `Timer` ticks `elapsedSeconds` once a second
  /// while `.recording`, surfacing `Recording… 0:12` in the status line (the recorder
  /// exposes no live zoom count, so an honest elapsed clock is shown instead).
  private var elapsedTimer: Timer?
  private var elapsedSeconds = 0

  /// Deferred-quit bookkeeping (ZR-904). When a quit arrives mid-pipeline we return
  /// `.terminateLater`; `replyToTermination()` sends the single reply either when the
  /// pipeline reaches `.idle` or when `terminationTimeoutTimer` fires (~60s cap).
  private var pendingTerminationReply = false
  private var didReplyToTermination = false
  private var terminationTimeoutTimer: Timer?

  /// Per-launch incrementing recording index, seeded from existing files so bundle
  /// names stay deterministic without ever calling `Date()`.
  private var recordingCounter = 1

  /// Quit can never hang past this many seconds, even if a render is wedged.
  private static let terminationTimeout: TimeInterval = 60

  /// Zoom magnifications offered in the submenu (default marked from `ZoomDefaults`).
  private static let zoomChoices: [(title: String, scale: Double)] = [
    ("1.5×", 1.5),
    ("2×", 2.0),
    ("3×", 3.0),
  ]

  // MARK: - Install

  /// Builds the status item + menu and prompts for missing grants. Must be called on
  /// the main thread.
  func install() {
    recordingCounter = nextRecordingIndex()

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.menu = buildMenu()
    statusItem = item
    refreshUI()

    OnboardingWindow.presentIfNeeded()
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false  // we manage isEnabled ourselves

    statusLineItem.title = statusLineText
    statusLineItem.isEnabled = false
    menu.addItem(statusLineItem)

    warningLineItem.title = "⚠ Hotkeys inactive — grant Accessibility (Stop from this menu)"
    warningLineItem.isEnabled = false
    warningLineItem.isHidden = true  // shown by refreshUI when Accessibility is missing
    menu.addItem(warningLineItem)

    menu.addItem(.separator())

    toggleItem.target = self
    toggleItem.action = #selector(toggleRecording(_:))
    menu.addItem(toggleItem)

    let zoomParent = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
    zoomParent.submenu = buildZoomMenu()
    menu.addItem(zoomParent)

    menu.addItem(.separator())

    revealItem.title = "Reveal Last Recording in Finder"
    revealItem.target = self
    revealItem.action = #selector(revealLast(_:))
    menu.addItem(revealItem)

    openItem.title = "Open Last Recording"
    openItem.target = self
    openItem.action = #selector(openLast(_:))
    menu.addItem(openItem)

    editItem.title = "Edit Last Recording…"
    editItem.target = self
    editItem.action = #selector(editLast(_:))
    menu.addItem(editItem)

    menu.addItem(.separator())

    permissionsItem.title = "Permissions…"
    permissionsItem.target = self
    permissionsItem.action = #selector(showPermissions(_:))
    menu.addItem(permissionsItem)

    let quitItem = NSMenuItem(
      title: "Quit zoooomrec", action: #selector(quit(_:)), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)

    return menu
  }

  private func buildZoomMenu() -> NSMenu {
    let zoomMenu = NSMenu()
    zoomMenu.autoenablesItems = false
    for choice in MenuBarController.zoomChoices {
      let item = NSMenuItem(
        title: choice.title, action: #selector(selectZoom(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = NSNumber(value: choice.scale)
      item.state = (choice.scale == selectedScale) ? .on : .off
      zoomMenu.addItem(item)
      zoomItems.append(item)
    }
    return zoomMenu
  }

  // MARK: - Menu actions (main thread)

  @objc private func toggleRecording(_ sender: NSMenuItem) {
    switch state {
    case .idle: startRecording()
    case .recording: stopRecording()
    case .rendering: break  // pipeline busy; item is disabled anyway
    }
  }

  @objc private func selectZoom(_ sender: NSMenuItem) {
    guard let scale = (sender.representedObject as? NSNumber)?.doubleValue else { return }
    selectedScale = scale
    for item in zoomItems {
      let value = (item.representedObject as? NSNumber)?.doubleValue
      item.state = (value == scale) ? .on : .off
    }
  }

  @objc private func revealLast(_ sender: NSMenuItem) {
    guard let url = lastRenderedMP4 else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  @objc private func openLast(_ sender: NSMenuItem) {
    guard let url = lastRenderedMP4 else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func editLast(_ sender: NSMenuItem) {
    guard let bundleURL = lastBundleURL else { return }
    EditorPresenter.present(bundleURL: bundleURL) { [weak self] mp4URL in
      // Contract: onRendered fires on main; re-dispatch defensively so state stays
      // main-confined regardless of the editor's threading.
      DispatchQueue.main.async {
        guard let self else { return }
        self.lastRenderedMP4 = mp4URL
        self.statusLineText = "Ready: \(mp4URL.lastPathComponent)"
        self.refreshUI()
      }
    }
  }

  @objc private func showPermissions(_ sender: NSMenuItem) {
    OnboardingWindow.present()
  }

  @objc private func quit(_ sender: NSMenuItem) {
    NSApp.terminate(nil)  // routes through applicationShouldTerminate (ZR-904)
  }

  // MARK: - Recording pipeline

  /// Starts a recording and, once stopped, auto-renders the zoom MP4. Runs the
  /// blocking `record(...)` + `render(...)` on a background `Task`; all UI updates
  /// hop back to the main queue.
  private func startRecording() {
    guard state == .idle else { return }
    guard PermissionsService.status().screenRecording else {
      statusLineText = "Screen Recording permission needed — open Permissions…"
      refreshUI()
      return
    }

    let index = recordingCounter
    recordingCounter += 1
    let name = "rec-\(index)"
    let bundleURL = recordingsDirectory.appendingPathComponent("\(name).zoooomrec")
    let mp4URL = recordingsDirectory.appendingPathComponent("\(name).mp4")
    let scale = selectedScale

    do {
      try FileManager.default.createDirectory(
        at: recordingsDirectory, withIntermediateDirectories: true)
    } catch {
      NSLog("zoooomrec: cannot create recordings directory: \(error)")
      statusLineText = "Error: cannot create ~/Movies/zoooomrec"
      refreshUI()
      return
    }

    let recorder = ScreenRecorder()
    activeRecorder = recorder
    state = .recording
    startElapsedTimer()
    statusLineText = recordingStatusText()  // "Recording… 0:00"
    refreshUI()

    Task { [weak self] in
      do {
        _ = try await recorder.record(durationSeconds: nil, zoomScale: scale, to: bundleURL)
        DispatchQueue.main.async { self?.didFinishRecording() }

        let throttle = RenderProgressThrottle { [weak self] percent in
          DispatchQueue.main.async {
            guard let self, self.state == .rendering else { return }
            self.statusLineText = "Rendering… \(percent)%"
            self.refreshUI()
          }
        }
        try await ZoomRenderer().render(projectBundle: bundleURL, outputURL: mp4URL) { fraction in
          throttle.report(fraction)
        }
        DispatchQueue.main.async {
          self?.didFinishRender(mp4URL: mp4URL, bundleURL: bundleURL, name: name)
        }
      } catch {
        NSLog("zoooomrec: \(name) failed: \(error)")
        DispatchQueue.main.async { self?.didFail(error: error) }
      }
    }
  }

  /// Requests the active recorder stop. `record(...)` then returns and the Task
  /// advances to rendering. Idempotent — safe to call more than once.
  private func stopRecording() {
    activeRecorder?.requestStop()
  }

  /// `record(...)` returned; the Task is now rendering.
  private func didFinishRecording() {
    guard state == .recording else { return }
    stopElapsedTimer()
    state = .rendering
    statusLineText = "Rendering…"
    refreshUI()
  }

  /// Render succeeded — enable reveal/open/edit and show the ready file (warning the
  /// user if the take captured no zooms or clicks). Replies to a pending quit.
  private func didFinishRender(mp4URL: URL, bundleURL: URL, name: String) {
    stopElapsedTimer()
    lastRenderedMP4 = mp4URL
    lastBundleURL = bundleURL
    activeRecorder = nil
    state = .idle
    statusLineText = readyStatusText(mp4Name: "\(name).mp4", bundleURL: bundleURL)
    refreshUI()
    replyToTerminationIfPending()
  }

  /// Record or render threw — return to idle with an error line. Never crashes.
  /// Replies to a pending quit so a mid-pipeline failure can't wedge the app open.
  private func didFail(error: Error) {
    stopElapsedTimer()
    activeRecorder = nil
    state = .idle
    statusLineText = "Error: \(shortMessage(for: error))"
    refreshUI()
    replyToTerminationIfPending()
  }

  // MARK: - Never lose a take (ZR-904)

  /// Refuses to abandon an in-flight take on quit. `.idle` quits immediately; a
  /// `.recording` take is stopped (which auto-renders) and a `.rendering` take is
  /// allowed to finish — both defer the reply until the pipeline lands.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    switch state {
    case .idle:
      return .terminateNow
    case .recording:
      stopRecording()  // record() returns → auto-render → didFinishRender replies
      beginPendingTermination()
      return .terminateLater
    case .rendering:
      beginPendingTermination()
      return .terminateLater
    }
  }

  private func beginPendingTermination() {
    pendingTerminationReply = true
    didReplyToTermination = false
    terminationTimeoutTimer?.invalidate()
    terminationTimeoutTimer = Timer.scheduledTimer(
      timeInterval: MenuBarController.terminationTimeout, target: self,
      selector: #selector(terminationTimedOut(_:)), userInfo: nil, repeats: false)
  }

  @objc private func terminationTimedOut(_ timer: Timer) {
    // Safety valve: never hang the quit, even if a render is wedged.
    replyToTermination()
  }

  private func replyToTerminationIfPending() {
    guard pendingTerminationReply else { return }
    replyToTermination()
  }

  private func replyToTermination() {
    guard pendingTerminationReply, !didReplyToTermination else { return }
    didReplyToTermination = true
    terminationTimeoutTimer?.invalidate()
    terminationTimeoutTimer = nil
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  // MARK: - Elapsed-time clock

  @objc private func tickElapsed(_ timer: Timer) {
    guard state == .recording else { return }
    elapsedSeconds += 1
    statusLineText = recordingStatusText()
    refreshUI()
  }

  private func recordingStatusText() -> String {
    String(format: "Recording… %d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
  }

  private func startElapsedTimer() {
    elapsedSeconds = 0
    elapsedTimer?.invalidate()
    elapsedTimer = Timer.scheduledTimer(
      timeInterval: 1.0, target: self, selector: #selector(tickElapsed(_:)),
      userInfo: nil, repeats: true)
  }

  private func stopElapsedTimer() {
    elapsedTimer?.invalidate()
    elapsedTimer = nil
  }

  // MARK: - UI refresh

  /// Reconciles every menu control with the current state and live grants. Main
  /// thread only.
  private func refreshUI() {
    let permissions = PermissionsService.status()

    setButtonImage()

    // Idle with no Screen Recording grant explains why Start is disabled; otherwise
    // the status line reflects the pipeline (Recording… / Rendering… / Ready / Error).
    if state == .idle && !permissions.screenRecording {
      statusLineItem.title = "Screen Recording permission needed — open Permissions…"
    } else {
      statusLineItem.title = statusLineText
    }

    // Persistent hotkey warning whenever Accessibility is missing — ⌃⌥S won't fire,
    // so the menu's Stop is the only way out of a recording.
    warningLineItem.isHidden = permissions.accessibility

    toggleItem.title = toggleTitle
    toggleItem.image = symbol(symbolName)
    switch state {
    case .idle: toggleItem.isEnabled = permissions.screenRecording
    case .recording: toggleItem.isEnabled = true  // Stop must stay reachable
    case .rendering: toggleItem.isEnabled = false  // pipeline busy
    }

    let hasRendered = (lastRenderedMP4 != nil)
    revealItem.isEnabled = hasRendered
    openItem.isEnabled = hasRendered
    editItem.isEnabled = (lastBundleURL != nil)
  }

  private func setButtonImage() {
    guard let button = statusItem?.button else { return }
    if let image = symbol(symbolName) {
      button.image = image
      button.title = ""
    } else {
      button.image = nil
      button.title = buttonFallbackTitle  // fallback if the SF Symbol is unavailable
    }
  }

  /// SF Symbol for the current state: idle ⇒ record, recording ⇒ stop, rendering ⇒ spinner.
  private var symbolName: String {
    switch state {
    case .idle: return "record.circle"
    case .recording: return "stop.circle.fill"
    case .rendering: return "arrow.triangle.2.circlepath"
    }
  }

  private var buttonFallbackTitle: String {
    switch state {
    case .idle: return "◉"
    case .recording: return "◉ REC"
    case .rendering: return "◉ ⟳"
    }
  }

  private var toggleTitle: String {
    switch state {
    case .idle: return "Start Recording"
    case .recording: return "Stop Recording"
    case .rendering: return "Rendering…"
    }
  }

  private func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: "zoooomrec")
  }

  // MARK: - Paths & helpers

  /// `~/Movies/zoooomrec`, where every recording bundle and rendered MP4 lives.
  private var recordingsDirectory: URL {
    let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
    return movies.appendingPathComponent("zoooomrec", isDirectory: true)
  }

  /// Highest existing `rec-<N>` index (bundle or MP4) + 1, or 1 when none exist.
  private func nextRecordingIndex() -> Int {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: recordingsDirectory.path)) ?? []
    var highest = 0
    for name in names where name.hasPrefix("rec-") {
      let stem = (name as NSString).deletingPathExtension  // "rec-<N>"
      if let value = Int(stem.dropFirst("rec-".count)) {
        highest = max(highest, value)
      }
    }
    return highest + 1
  }

  /// The "Ready" line, appending a nudge when the take recorded nothing to zoom on.
  private func readyStatusText(mp4Name: String, bundleURL: URL) -> String {
    if bundleHasZoomOrClick(bundleURL: bundleURL) {
      return "Ready: \(mp4Name)"
    }
    return "Ready: \(mp4Name) (no zooms — use ⌃⌥Z or click while recording)"
  }

  /// Scans the bundle's `events.jsonl` for any `zoom_in` marker or `left_click` /
  /// `right_click`. Foundation-only and forward-compatible: unparsable or
  /// unknown-`kind` lines are skipped, never fatal. An unreadable file counts as
  /// "no zooms" so the helpful nudge still shows.
  private func bundleHasZoomOrClick(bundleURL: URL) -> Bool {
    let eventsURL = bundleURL.appendingPathComponent(ZoooomrecBundle.eventsName)
    guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return false }
    for line in text.split(whereSeparator: \.isNewline) {
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let kind = object["kind"] as? String
      else { continue }
      if kind == "zoom_in" || kind == "left_click" || kind == "right_click" {
        return true
      }
    }
    return false
  }

  /// A short, single-line error message for the status line.
  private func shortMessage(for error: Error) -> String {
    if case CaptureError.screenRecordingPermissionDenied = error {
      return "screen recording permission denied"
    }
    let full = String(describing: error)
    let firstLine = full.split(whereSeparator: \.isNewline).first.map(String.init) ?? full
    return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
  }
}

/// Serializes render progress into ~decile status updates, mirroring the CLI's
/// `ProgressPrinter`. The render pipeline calls `report(_:)` from its own serial
/// queue, and the lock keeps `lastDecile` race-free; the callback (main-hop) fires
/// only when the whole-decile percentage advances.
private final class RenderProgressThrottle: @unchecked Sendable {
  private let lock = NSLock()
  private var lastDecile = -1
  private let onPercent: @Sendable (Int) -> Void

  init(_ onPercent: @escaping @Sendable (Int) -> Void) {
    self.onPercent = onPercent
  }

  func report(_ fraction: Double) {
    lock.lock()
    let decile = min(10, max(0, Int(fraction * 10)))
    let advanced = decile > lastDecile
    if advanced { lastDecile = decile }
    lock.unlock()
    guard advanced else { return }
    onPercent(decile * 10)
  }
}
