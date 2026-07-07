import AppKit
import Foundation

/// Entry point for the menu-bar app (`zoooomrec app`).
///
/// Uses AppKit `NSStatusItem` + `NSMenu` (not SwiftUI `MenuBarExtra`, which needs an
/// `@main App` lifecycle + app bundle and is unreliable from a bare SwiftPM binary).
/// Launched via `zoooomrec app` from the terminal, it inherits the terminal's TCC
/// (Screen Recording + Accessibility) grants.
public enum ZoooomrecApp {
  /// Retains the controller for the app's lifetime so the `NSStatusItem` it owns
  /// does not vanish (the classic status-item-deallocated trap).
  private static var controller: MenuBarController?

  /// Installs the menu-bar UI and runs the AppKit event loop. Blocks until Quit —
  /// correct for an app entry point. Must be called on the main thread.
  public static func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // menu-bar only: no Dock icon, no focus stealing

    let controller = MenuBarController()
    controller.install()
    ZoooomrecApp.controller = controller

    app.run()
  }
}
