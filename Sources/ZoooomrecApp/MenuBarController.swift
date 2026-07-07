import AppKit
import CaptureEngine
import Foundation
import RenderEngine
import ZoomTypes

/// Drives the zoooomrec menu-bar app: an `NSStatusItem` + `NSMenu` that starts/stops
/// a recording and picks the zoom scale entirely from the menu bar — no terminal.
///
/// AppKit rule: `NSStatusItem` / `NSMenu` are main-thread only. Menu target-action
/// callbacks already arrive on the main thread; the background recording `Task`
/// marshals every UI mutation back to the main queue. The `NSStatusItem` is retained
/// here (and this controller is retained by `ZoooomrecApp`) so it never vanishes.
///
/// `@unchecked Sendable`: every stored property is touched only on the main thread.
/// The recording `Task` reads no state after spawn and reports each phase transition
/// back through `DispatchQueue.main.async`, so the cross-actor capture is safe.
final class MenuBarController: NSObject, @unchecked Sendable {
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
  private let revealItem = NSMenuItem()
  private let openItem = NSMenuItem()
  private var zoomItems: [NSMenuItem] = []

  // Recording state (mutated on the main thread only).
  private var state: State = .idle
  private var statusLineText = "Idle"
  private var selectedScale = ZoomDefaults.scale
  private var lastRenderedMP4: URL?
  private var activeRecorder: ScreenRecorder?

  /// Per-launch incrementing recording index, seeded from existing files so bundle
  /// names stay deterministic without ever calling `Date()`.
  private var recordingCounter = 1

  /// Zoom magnifications offered in the submenu (default marked from `ZoomDefaults`).
  private static let zoomChoices: [(title: String, scale: Double)] = [
    ("1.5×", 1.5),
    ("2×", 2.0),
    ("3×", 3.0),
  ]

  // MARK: - Install

  /// Builds the status item + menu. Must be called on the main thread.
  func install() {
    recordingCounter = nextRecordingIndex()

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.menu = buildMenu()
    statusItem = item
    refreshUI()
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false  // we manage isEnabled ourselves

    statusLineItem.title = statusLineText
    statusLineItem.isEnabled = false
    menu.addItem(statusLineItem)

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

    menu.addItem(.separator())

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

  @objc private func quit(_ sender: NSMenuItem) {
    NSApp.terminate(nil)
  }

  // MARK: - Recording pipeline

  /// Starts a recording and, once stopped, auto-renders the zoom MP4. Runs the
  /// blocking `record(...)` + `render(...)` on a background `Task`; all UI updates
  /// hop back to the main queue.
  private func startRecording() {
    guard state == .idle else { return }

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
    statusLineText = "Recording…"
    refreshUI()

    Task { [weak self] in
      do {
        _ = try await recorder.record(durationSeconds: nil, zoomScale: scale, to: bundleURL)
        DispatchQueue.main.async { self?.didFinishRecording() }
        try await ZoomRenderer().render(projectBundle: bundleURL, outputURL: mp4URL)
        DispatchQueue.main.async { self?.didFinishRender(mp4URL: mp4URL, name: name) }
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
    state = .rendering
    statusLineText = "Rendering…"
    refreshUI()
  }

  /// Render succeeded — enable reveal/open and show the ready file.
  private func didFinishRender(mp4URL: URL, name: String) {
    lastRenderedMP4 = mp4URL
    activeRecorder = nil
    state = .idle
    statusLineText = "Ready: \(name).mp4"
    refreshUI()
  }

  /// Record or render threw — return to idle with an error line. Never crashes.
  private func didFail(error: Error) {
    activeRecorder = nil
    state = .idle
    statusLineText = "Error: \(shortMessage(for: error))"
    refreshUI()
  }

  // MARK: - UI refresh

  /// Reconciles every menu control with the current state. Main thread only.
  private func refreshUI() {
    let recording = (state == .recording)

    setButtonImage(recording: recording)
    statusLineItem.title = statusLineText

    toggleItem.title = recording ? "Stop Recording" : "Start Recording"
    toggleItem.image = symbol(recording ? "stop.circle.fill" : "record.circle")
    toggleItem.isEnabled = (state != .rendering)

    let hasRecording = (lastRenderedMP4 != nil)
    revealItem.isEnabled = hasRecording
    openItem.isEnabled = hasRecording
  }

  private func setButtonImage(recording: Bool) {
    let symbolName = recording ? "stop.circle.fill" : "record.circle"
    guard let button = statusItem?.button else { return }
    if let image = symbol(symbolName) {
      button.image = image
      button.title = ""
    } else {
      button.image = nil
      button.title = recording ? "◉ REC" : "◉"  // fallback if SF Symbol is unavailable
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
