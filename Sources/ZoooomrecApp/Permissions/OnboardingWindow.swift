import AppKit
import Foundation

/// The first-launch / missing-permission window.
///
/// Retains a single controller in a static so the `NSWindow` is never released while
/// open. All entry points are marshalled to the main thread — AppKit is main-thread only.
enum OnboardingWindow {
  /// Retained for the window's lifetime; nilled when the window closes.
  private static var controller: OnboardingWindowController?

  /// Shows the window only when a required grant is missing. No-op otherwise.
  static func presentIfNeeded() {
    guard !PermissionsService.status().allGranted else { return }
    present()
  }

  /// Always shows the window (menu item "Permissions…"). Reuses the existing one.
  static func present() {
    onMain {
      if let existing = controller {
        existing.bringToFront()
        return
      }
      let created = OnboardingWindowController { controller = nil }
      controller = created
      created.bringToFront()
    }
  }

  private static func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }
}

/// Owns the permissions window: two `PermissionRow`s, a Relaunch button, and a Done
/// button. Polls `PermissionsService.status()` on a ~1s timer while open because macOS
/// gives the app no callback when the user flips a toggle in System Settings and returns.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
  private let window: NSWindow
  private let screenRow: PermissionRow
  private let accessibilityRow: PermissionRow
  private let doneButton = NSButton(title: "Done", target: nil, action: nil)
  private var pollTimer: Timer?
  private let onClose: () -> Void

  private static let innerWidth: CGFloat = 420
  private static let inset: CGFloat = 20

  init(onClose: @escaping () -> Void) {
    self.onClose = onClose

    screenRow = PermissionRow(
      title: "Screen Recording",
      detail: "Required to record your screen.",
      actionTitle: "Grant",
      action: {
        // First launch shows the system prompt; afterwards the pane is where the
        // toggle lives, so open both.
        PermissionsService.requestScreenRecording()
        PermissionsService.openScreenRecordingSettings()
      })

    accessibilityRow = PermissionRow(
      title: "Accessibility",
      detail:
        "Required for the ⌃⌥Z / ⌃⌥X / ⌃⌥S hotkeys. Without it, recording still works but no hotkey will respond, including Stop.",
      actionTitle: "Open Settings",
      action: { PermissionsService.openAccessibilitySettings() })

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: OnboardingWindowController.innerWidth, height: 10),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.title = "zoooomrec — Permissions"
    // ARC owns `window`; without this, closing it triggers an over-release and crash.
    window.isReleasedWhenClosed = false

    super.init()

    window.delegate = self
    buildContent()
    window.center()
    refresh()
  }

  // MARK: - Presentation

  /// Bring the window forward. `NSApp.activate` is required for an `.accessory` app's
  /// window to become visible and key.
  func bringToFront() {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    startPolling()
    refresh()
  }

  // MARK: - Live status

  /// Reconcile every row + the Done button with the current grant state. Main thread only.
  private func refresh() {
    let status = PermissionsService.status()
    screenRow.update(granted: status.screenRecording)
    accessibilityRow.update(granted: status.accessibility)
    doneButton.isEnabled = status.allGranted
  }

  private func startPolling() {
    guard pollTimer == nil else { return }
    // `.common` mode so it keeps firing while a menu or modal is tracking.
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh() }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  // MARK: - NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    pollTimer?.invalidate()
    pollTimer = nil
    onClose()
  }

  // MARK: - Actions

  @objc private func relaunchTapped() {
    PermissionsService.relaunch()
  }

  @objc private func doneTapped() {
    window.close()
  }

  // MARK: - Layout

  private func buildContent() {
    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 16
    root.translatesAutoresizingMaskIntoConstraints = false

    let intro = makeWrappingLabel(
      "zoooomrec needs these macOS permissions. Grant each one, then relaunch.",
      secondary: true)

    addFullWidth(intro, to: root)
    addFullWidth(screenRow, to: root)
    addFullWidth(accessibilityRow, to: root)
    addFullWidth(makeSeparator(), to: root)

    let relaunchCaption = makeWrappingLabel(
      "macOS only applies a new Screen Recording grant after a restart.", secondary: true)
    addFullWidth(relaunchCaption, to: root)

    let relaunchButton = NSButton(
      title: "Relaunch zoooomrec", target: self, action: #selector(relaunchTapped))
    relaunchButton.bezelStyle = .rounded
    relaunchButton.controlSize = .large
    root.addArrangedSubview(relaunchButton)  // left-aligned, hugs its title

    addFullWidth(makeSeparator(), to: root)

    doneButton.target = self
    doneButton.action = #selector(doneTapped)
    doneButton.bezelStyle = .rounded
    doneButton.keyEquivalent = "\r"  // default button
    let footer = NSStackView()
    footer.orientation = .horizontal
    footer.addView(doneButton, in: .trailing)
    addFullWidth(footer, to: root)

    let content = NSView()
    content.addSubview(root)
    window.contentView = content

    let inset = OnboardingWindowController.inset
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
      root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
      root.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
      root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
      root.widthAnchor.constraint(equalToConstant: OnboardingWindowController.innerWidth),
    ])
  }

  private func addFullWidth(_ view: NSView, to stack: NSStackView) {
    stack.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }

  private func makeWrappingLabel(_ text: String, secondary: Bool) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.preferredMaxLayoutWidth = OnboardingWindowController.innerWidth
    if secondary { label.textColor = .secondaryLabelColor }
    return label
  }

  private func makeSeparator() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    return box
  }
}
