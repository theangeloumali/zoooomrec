import Foundation
import ZoomTypes

/// Builds zoom segments from live hotkey markers captured during recording.
///
/// Unlike ``AutoZoom`` (which infers zooms from click clusters), this path is driven
/// explicitly by the user: a `.zoomIn` marker opens a zoom at the cursor, a `.zoomOut`
/// closes it. This is the manual, deliberate zoom lane.
public enum ManualZoom {
    /// Compiles time-sorted `.zoomIn` / `.zoomOut` markers into zoom segments.
    ///
    /// - A `.zoomIn` opens a segment at its `(x, y)` with `scale`, starting at its `t`.
    /// - A `.zoomIn` while one is OPEN is a retarget: the current segment ends at this `t`
    ///   and a new CONTIGUOUS segment (start == previous end) opens at the new center, so
    ///   the spring pans between them without releasing the zoom.
    /// - A `.zoomOut` closes the open segment at its `t`; a `.zoomOut` with nothing open is ignored.
    /// - An unclosed open segment runs to `duration`.
    ///
    /// Emitted centers are raw cursor positions — like ``AutoZoom``, this lane relies on
    /// ``ZoomTimeline`` to clamp each frame's target in-frame (one source of truth). Output
    /// is sorted, non-overlapping, and contiguous exactly where a retarget occurred.
    public static func segments(
        from events: [InputEvent],
        width: Double,
        height: Double,
        scale: Double,
        duration: Double
    ) -> [ZoomSegment] {
        let markers = events
            .filter { $0.kind == .zoomIn || $0.kind == .zoomOut }
            .sorted { $0.t < $1.t }

        var segments: [ZoomSegment] = []
        var openStart: Double?
        var openCenter: (x: Double, y: Double) = (width / 2, height / 2)

        func closeOpen(at end: Double) {
            guard let start = openStart else { return }
            segments.append(
                ZoomSegment(
                    start: start, end: end,
                    centerX: openCenter.x, centerY: openCenter.y, scale: scale))
        }

        for marker in markers {
            switch marker.kind {
            case .zoomIn:
                // A zoomIn while open is a retarget: close here, reopen contiguously.
                closeOpen(at: marker.t)
                openStart = marker.t
                openCenter = (marker.x, marker.y)
            case .zoomOut:
                closeOpen(at: marker.t)
                openStart = nil
            default:
                break
            }
        }

        // An unclosed zoom runs to the end of the clip.
        if let start = openStart, duration > start {
            segments.append(
                ZoomSegment(
                    start: start, end: duration,
                    centerX: openCenter.x, centerY: openCenter.y, scale: scale))
        }

        return segments
    }
}
