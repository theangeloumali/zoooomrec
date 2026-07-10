import XCTest
import ZoomTypes

@testable import RenderEngine

/// Regression guard for the record-time `zoomScale` reaching the click-driven
/// auto-zoom lane. `ZoomRenderer` used to call `AutoZoom.segments` with no config, so
/// click auto-zoom always rendered at `AutoZoomConfig`'s 2.0 default and silently
/// ignored `--zoom-scale`; only the manual hotkey lane honored the user's scale.
final class ZoomScaleWiringTests: XCTestCase {
    private func manifest(zoomScale: Double?) -> ProjectManifest {
        ProjectManifest(
            pixelWidth: 1920, pixelHeight: 1080, fps: 60,
            durationSeconds: 10, segments: nil, zoomScale: zoomScale)
    }

    // A click-only stream with manifest zoomScale 3.0 must yield segments at scale 3.0,
    // not the 2.0 default — the bug this packet fixes.
    func testClickAutoZoomHonorsManifestZoomScale() {
        let events = [
            InputEvent(t: 1.0, kind: .leftClick, x: 800, y: 400),
            InputEvent(t: 1.4, kind: .leftClick, x: 810, y: 400),
        ]
        let segments = ZoomRenderer.compileSegments(
            manifest: manifest(zoomScale: 3.0), events: events, duration: 10)
        XCTAssertFalse(segments.isEmpty, "a click cluster must produce a zoom segment")
        for segment in segments {
            XCTAssertEqual(
                segment.scale, 3.0, accuracy: 1e-9,
                "auto-zoom must use the manifest zoomScale, not AutoZoomConfig's 2.0 default")
        }
    }

    // An absent zoomScale falls back to the shared default (2.0) — guards against a
    // naive fix that hardcodes a scale instead of honoring ZoomDefaults.
    func testClickAutoZoomFallsBackToDefaultScale() {
        let events = [InputEvent(t: 1.0, kind: .leftClick, x: 800, y: 400)]
        let segments = ZoomRenderer.compileSegments(
            manifest: manifest(zoomScale: nil), events: events, duration: 10)
        XCTAssertFalse(segments.isEmpty)
        for segment in segments {
            XCTAssertEqual(segment.scale, ZoomDefaults.scale, accuracy: 1e-9)
        }
    }

    // The manual hotkey lane must honor the same zoomScale (and win over auto-zoom).
    func testManualZoomLaneHonorsManifestZoomScale() {
        let events = [
            InputEvent(t: 1.0, kind: .zoomIn, x: 900, y: 500),
            InputEvent(t: 4.0, kind: .zoomOut, x: 0, y: 0),
        ]
        let segments = ZoomRenderer.compileSegments(
            manifest: manifest(zoomScale: 3.0), events: events, duration: 10)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].scale, 3.0, accuracy: 1e-9)
    }
}
