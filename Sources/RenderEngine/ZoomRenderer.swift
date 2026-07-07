import Foundation
import ZoomTypes

// Owned by the RenderEngine packet — replace this file, keep the public API.
public struct ZoomRenderer {
    public init() {}

    /// Renders a `.zoooomrec` bundle into a zoom-animated MP4 (stub).
    public func render(
        projectBundle: URL,
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        throw NSError(
            domain: "zoooomrec.render",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "RenderEngine is not implemented yet (scaffold stub)"]
        )
    }
}
