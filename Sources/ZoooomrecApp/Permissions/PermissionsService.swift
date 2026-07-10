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
/// Owned by the Permissions packet — replace this stub, keep the API.
enum PermissionsService {
    /// Current grant state. Must never block or prompt.
    static func status() -> PermissionStatus {
        PermissionStatus(screenRecording: true, accessibility: true)
    }

    /// Triggers the system Screen Recording prompt (once per app identity).
    static func requestScreenRecording() {}

    /// Accessibility cannot be granted programmatically — deep-link the user instead.
    static func openAccessibilitySettings() {}

    /// Deep-link to the Screen Recording pane.
    static func openScreenRecordingSettings() {}

    /// Relaunch the app; macOS only honors a fresh Screen Recording grant after restart.
    static func relaunch() {}
}

/// The first-launch / missing-permission window.
///
/// Owned by the Permissions packet — replace this stub, keep the API.
enum OnboardingWindow {
    /// Shows the onboarding window when any required grant is missing. No-op otherwise.
    static func presentIfNeeded() {}

    /// Always shows the window (menu item "Permissions…").
    static func present() {}
}
