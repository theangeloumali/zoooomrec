import Foundation
import ZoomTypes

// Owned by the CaptureEngine packet — replace this file, keep the public API.
public final class ScreenRecorder {
    public init() {}

    /// Records the main display into a `.zoooomrec` bundle directory (stub).
    public func record(durationSeconds: Double, to bundleURL: URL) async throws -> ProjectManifest {
        throw NSError(
            domain: "zoooomrec.capture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "CaptureEngine is not implemented yet (scaffold stub)"]
        )
    }
}
