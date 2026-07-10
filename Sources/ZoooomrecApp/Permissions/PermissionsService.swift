import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Which TCC grants zoooomrec currently holds.
///
/// Screen Recording is required to capture at all. Accessibility backs the CGEventTap,
/// so without it every hotkey — including ⌃⌥S Stop — silently does nothing.
struct PermissionStatus: Equatable {
  var screenRecording: Bool
  var accessibility: Bool

  var allGranted: Bool { screenRecording && accessibility }
}

/// Reads and requests the TCC grants the app needs.
///
/// Two hard macOS truths shape this API:
/// - **Screen Recording** can be preflighted (`CGPreflightScreenCaptureAccess`) and
///   prompted once per app identity (`CGRequestScreenCaptureAccess`), but a *fresh*
///   grant only takes effect after the app relaunches — hence `relaunch()`.
/// - **Accessibility** cannot be granted programmatically at all. We can only read it
///   (`AXIsProcessTrusted`) and deep-link the user to the System Settings pane.
enum PermissionsService {
  /// Current grant state. Never blocks and never prompts — safe to poll on a timer.
  static func status() -> PermissionStatus {
    PermissionStatus(
      screenRecording: CGPreflightScreenCaptureAccess(),
      accessibility: AXIsProcessTrusted()
    )
  }

  /// Triggers the system Screen Recording prompt (once per app identity). The returned
  /// state is ignored: the real grant lands only after `relaunch()`, so callers poll
  /// `status()` on return instead of trusting this value.
  static func requestScreenRecording() {
    _ = CGRequestScreenCaptureAccess()
  }

  /// Accessibility cannot be granted programmatically — deep-link the user to the pane.
  static func openAccessibilitySettings() {
    openPrivacyPane("Privacy_Accessibility")
  }

  /// Deep-link to the Screen Recording pane so the user can flip the toggle after the
  /// one-time prompt.
  static func openScreenRecordingSettings() {
    openPrivacyPane("Privacy_ScreenCapture")
  }

  /// Relaunch the app; macOS only honors a fresh Screen Recording grant after a restart.
  ///
  /// Works when running as a real `.app` bundle. When launched as a bare CLI binary
  /// (`.build/debug/zoooomrec app`) there is no bundle to relaunch, so we degrade to a
  /// printed instruction instead of silently doing nothing.
  static func relaunch() {
    let bundleURL = Bundle.main.bundleURL
    guard bundleURL.pathExtension == "app" else {
      FileHandle.standardError.write(
        Data(
          "zoooomrec: relaunch needs the .app bundle — quit and run `zoooomrec app` again to apply the new Screen Recording grant.\n"
            .utf8))
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
      // Completion runs off the main thread; AppKit teardown must hop back.
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }
  }

  private static func openPrivacyPane(_ anchor: String) {
    guard
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    else { return }
    NSWorkspace.shared.open(url)
  }
}
