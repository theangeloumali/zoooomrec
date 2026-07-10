import AVFoundation
import Foundation
import RenderEngine
import XCTest
import ZoomEngine
import ZoomTypes

/// End-to-end proof that the synthetic pointer is drawn for v2 bundles, suppressed for legacy
/// v1 bundles, hidden when idle, and mapped through the zoom crop (never enlarged by it).
///
/// All four tests render a real `.zoooomrec` bundle through `ZoomRenderer` and sample the
/// decoded output pixels — the cursor track (`CursorTrack`, built by the renderer with the same
/// default `CursorConfig`) is re-derived in-test only to know WHERE to look.
final class CursorRenderTests: XCTestCase {
    /// v2 bundle (`cursorBurnedIn: false`), straight-line move track, no zoom → identity crop.
    /// The pointer must appear at the cursor coordinate; a point far away must stay background.
    func testSyntheticCursorDrawnForV2Bundle() async throws {
        let width = 1920, height = 1080, fps = 24
        let clip = SyntheticClip(width: width, height: height, fps: fps, durationSeconds: 1.2)
        let moves = Self.horizontalMoves(y: 140, xStart: 300, xEnd: 1200,
                                         fromT: 0.0, toT: 1.2, step: 0.1)
        let manifest = ProjectManifest(
            pixelWidth: width, pixelHeight: height, fps: Double(fps),
            durationSeconds: 1.2, cursorBurnedIn: false)

        let (bundleURL, workDir) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workDir) }
        try await Self.write(clip: clip, manifest: manifest, events: moves, to: bundleURL)

        let outputURL = workDir.appendingPathComponent("out.mp4")
        try await ZoomRenderer().render(projectBundle: bundleURL, outputURL: outputURL)

        let inputAsset = AVURLAsset(url: bundleURL.appendingPathComponent(ZoooomrecBundle.videoName))
        let outputAsset = AVURLAsset(url: outputURL)

        let index = 14
        let sampleT = Double(index) / Double(fps)
        let expected = try XCTUnwrap(
            CursorTrack.frame(at: sampleT, moves: moves, config: CursorConfig()),
            "the moving cursor should be visible mid-clip")
        XCTAssertGreaterThan(expected.opacity, 0.5, "a continuously moving cursor stays opaque")

        let output = try await frame(from: outputAsset, at: sampleT)
        let input = try await frame(from: inputAsset, at: sampleT)

        // Identity crop → tip sits at the raw capture coordinate. The arrow body runs down-right.
        let tipX = Int(expected.position.x.rounded())
        let tipY = Int(expected.position.y.rounded())
        let bright = Self.maxLuma(in: output, x: tipX - 2, y: tipY - 2, w: 22, h: 30)
        XCTAssertGreaterThan(bright, 150,
                             "the pointer's white outline should be present at the cursor coordinate")

        // Far from the cursor: background is untouched by compositing.
        let farOut = output.luma(x: 1500, y: 950)
        let farIn = input.luma(x: 1500, y: 950)
        XCTAssertLessThan(farOut, 80, "a point far from the cursor stays dark background")
        XCTAssertEqual(farOut, farIn, accuracy: 10, "background far from the cursor is unchanged")
    }

    /// Legacy v1 bundle (`cursorBurnedIn` absent → nil → burned-in). No synthetic cursor may be
    /// drawn, or the frame would show two pointers.
    func testNoSyntheticCursorForV1BurnedInBundle() async throws {
        let width = 1920, height = 1080, fps = 24
        let clip = SyntheticClip(width: width, height: height, fps: fps, durationSeconds: 1.2)
        let moves = Self.horizontalMoves(y: 140, xStart: 300, xEnd: 1200,
                                         fromT: 0.0, toT: 1.2, step: 0.1)
        // No cursorBurnedIn → nil → treated as v1 (pointer already in the pixels).
        let manifest = ProjectManifest(
            pixelWidth: width, pixelHeight: height, fps: Double(fps), durationSeconds: 1.2)

        let (bundleURL, workDir) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workDir) }
        try await Self.write(clip: clip, manifest: manifest, events: moves, to: bundleURL)

        let outputURL = workDir.appendingPathComponent("out.mp4")
        try await ZoomRenderer().render(projectBundle: bundleURL, outputURL: outputURL)

        let outputAsset = AVURLAsset(url: outputURL)
        let index = 14
        let sampleT = Double(index) / Double(fps)
        let where0 = try XCTUnwrap(CursorTrack.frame(at: sampleT, moves: moves, config: CursorConfig()))
        let output = try await frame(from: outputAsset, at: sampleT)

        // The would-be cursor location must remain flat background — nothing was drawn.
        let tipX = Int(where0.position.x.rounded())
        let tipY = Int(where0.position.y.rounded())
        let bright = Self.maxLuma(in: output, x: tipX - 2, y: tipY - 2, w: 22, h: 30)
        XCTAssertLessThan(bright, 80, "a v1 burned-in bundle must not draw a synthetic cursor")
    }

    /// A move track that goes stationary must fade to hidden: a late frame has `opacity == 0`,
    /// so no cursor is drawn there — while an early (moving) frame still shows one.
    func testIdleCursorFadesToHidden() async throws {
        let width = 1920, height = 1080, fps = 12
        let clip = SyntheticClip(width: width, height: height, fps: fps, durationSeconds: 6.0)
        // Move for the first ~0.5s, then hold still at (500, 200) for the rest of the clip.
        let moves = Self.horizontalMoves(y: 200, xStart: 400, xEnd: 500,
                                         fromT: 0.0, toT: 0.5, step: 0.1)
        let restX = 500.0, restY = 200.0
        let manifest = ProjectManifest(
            pixelWidth: width, pixelHeight: height, fps: Double(fps),
            durationSeconds: 6.0, cursorBurnedIn: false)

        let (bundleURL, workDir) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workDir) }
        try await Self.write(clip: clip, manifest: manifest, events: moves, to: bundleURL)

        let outputURL = workDir.appendingPathComponent("out.mp4")
        try await ZoomRenderer().render(projectBundle: bundleURL, outputURL: outputURL)
        let outputAsset = AVURLAsset(url: outputURL)

        // Find a late frame where the cursor is hidden, using the renderer's own default config.
        let frameCount = clip.frameCount
        var hiddenT: Double?
        var index = frameCount - 1
        while index >= 0 {
            let t = Double(index) / Double(fps)
            let cursor = CursorTrack.frame(at: t, moves: moves, config: CursorConfig())
            if cursor == nil || (cursor?.opacity ?? 0) <= 0.001 {
                hiddenT = t
                index -= 1
            } else {
                break
            }
        }
        let hidden = try XCTUnwrap(hiddenT, "the idle cursor should fade out before the clip ends")

        // Positive control: an early moving frame DOES draw the cursor.
        let activeT = 0.25
        let active = try XCTUnwrap(CursorTrack.frame(at: activeT, moves: moves, config: CursorConfig()))
        XCTAssertGreaterThan(active.opacity, 0.5)
        let activeFrame = try await frame(from: outputAsset, at: activeT)
        let activeBright = Self.maxLuma(
            in: activeFrame,
            x: Int(active.position.x.rounded()) - 2, y: Int(active.position.y.rounded()) - 2,
            w: 22, h: 30)
        XCTAssertGreaterThan(activeBright, 150, "the cursor is visible while it is moving")

        // The hidden late frame draws nothing at the stationary position.
        let hiddenFrame = try await frame(from: outputAsset, at: hidden)
        let hiddenBright = Self.maxLuma(
            in: hiddenFrame, x: Int(restX.rounded()) - 2, y: Int(restY.rounded()) - 2, w: 22, h: 30)
        XCTAssertLessThan(hiddenBright, 80, "an idle-faded cursor must not be drawn")
    }

    /// With an explicit zoom segment active, the cursor lands at the correct OUTPUT coordinate
    /// (proving the crop→output mapping) and keeps a constant size — it is not scaled up by the
    /// crop.
    func testCursorLandsAtOutputCoordinateWhenZoomed() async throws {
        let width = 1920, height = 1080, fps = 24
        let clip = SyntheticClip(width: width, height: height, fps: fps, durationSeconds: 1.6)
        // Hover near (480, 260), oscillating a little so the cursor never idles out.
        var moves: [InputEvent] = []
        var t = 0.0
        var toggle = false
        while t <= 1.6 + 1e-9 {
            moves.append(InputEvent(t: t, kind: .move, x: 480 + (toggle ? 12 : -12), y: 260))
            toggle.toggle()
            t += 0.1
        }
        let segment = ZoomSegment(start: 0.3, end: 1.3, centerX: 480, centerY: 260, scale: 2.0)
        let manifest = ProjectManifest(
            pixelWidth: width, pixelHeight: height, fps: Double(fps),
            durationSeconds: 1.6, segments: [segment], cursorBurnedIn: false)

        let (bundleURL, workDir) = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workDir) }
        try await Self.write(clip: clip, manifest: manifest, events: moves, to: bundleURL)

        let outputURL = workDir.appendingPathComponent("out.mp4")
        try await ZoomRenderer().render(projectBundle: bundleURL, outputURL: outputURL)

        let inputAsset = AVURLAsset(url: bundleURL.appendingPathComponent(ZoooomrecBundle.videoName))
        let outputAsset = AVURLAsset(url: outputURL)
        let duration = try await inputAsset.load(.duration).seconds

        // Reproduce the renderer's crop keyframes exactly, then map the cursor through the crop.
        let keyframes = ZoomTimeline.cropKeyframes(
            segments: [segment], events: moves,
            width: Double(width), height: Double(height), fps: Double(fps), duration: duration)
        let index = 22
        let sampleT = Double(index) / Double(fps)
        let kfIndex = min(max(0, Int((sampleT * Double(fps)).rounded())), keyframes.count - 1)
        let crop = keyframes[kfIndex].rect
        XCTAssertGreaterThan(crop.width, 0)
        XCTAssertLessThan(crop.width, Double(width),
                          "the segment should be zoomed in (crop narrower than the frame) mid-segment")

        let cursor = try XCTUnwrap(CursorTrack.frame(at: sampleT, moves: moves, config: CursorConfig()))
        XCTAssertGreaterThan(cursor.opacity, 0.5)

        let outX = (cursor.position.x - crop.minX) * (Double(width) / crop.width)
        let outYTopLeft = (cursor.position.y - crop.minY) * (Double(height) / crop.height)

        let output = try await frame(from: outputAsset, at: sampleT)
        let tipX = Int(outX.rounded())
        let tipY = Int(outYTopLeft.rounded())
        let bright = Self.maxLuma(in: output, x: tipX - 2, y: tipY - 2, w: 24, h: 32)
        XCTAssertGreaterThan(bright, 150,
                             "the cursor should land at the mapped OUTPUT coordinate under zoom")

        // Not scaled up: the bright pointer spans roughly its unscaled height (~20px at 1080p),
        // not the ~2× a crop-scaled sprite would produce.
        let extent = Self.brightVerticalExtent(
            in: output, cx: tipX, cy: tipY, half: 40, threshold: 150)
        XCTAssertGreaterThan(extent, 6, "the pointer is actually present")
        XCTAssertLessThan(extent, 34, "the pointer must not balloon with the crop scale")
    }

    // MARK: - Fixtures

    private func makeWorkspace() throws -> (bundle: URL, workDir: URL) {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoooomrec-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let bundleURL = workDir.appendingPathComponent("clip.zoooomrec")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return (bundleURL, workDir)
    }

    private static func write(
        clip: SyntheticClip, manifest: ProjectManifest, events: [InputEvent], to bundleURL: URL
    ) async throws {
        try await clip.write(to: bundleURL.appendingPathComponent(ZoooomrecBundle.videoName))
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: bundleURL.appendingPathComponent(ZoooomrecBundle.manifestName))
        try writeEventsJSONL(events, to: bundleURL.appendingPathComponent(ZoooomrecBundle.eventsName))
    }

    /// A continuous horizontal `move` track — one sample every `step` seconds so the cursor keeps
    /// moving (and so stays opaque).
    private static func horizontalMoves(
        y: Double, xStart: Double, xEnd: Double, fromT: Double, toT: Double, step: Double
    ) -> [InputEvent] {
        var events: [InputEvent] = []
        let span = max(toT - fromT, 1e-9)
        var t = fromT
        while t <= toT + 1e-9 {
            let fraction = (t - fromT) / span
            events.append(InputEvent(t: t, kind: .move, x: xStart + fraction * (xEnd - xStart), y: y))
            t += step
        }
        return events
    }

    // MARK: - Pixel helpers

    /// Brightest luma in an axis-aligned window (top-left origin, clamped to bounds).
    private static func maxLuma(in raster: RasterImage, x: Int, y: Int, w: Int, h: Int) -> Double {
        var peak = 0.0
        for py in y..<(y + h) {
            for px in x..<(x + w) {
                peak = max(peak, raster.luma(x: px, y: py))
            }
        }
        return peak
    }

    /// Vertical span (maxY − minY) of pixels brighter than `threshold` within a square window
    /// centered on `(cx, cy)`; `0` when none qualify. Measures the pointer's drawn height.
    private static func brightVerticalExtent(
        in raster: RasterImage, cx: Int, cy: Int, half: Int, threshold: Double
    ) -> Int {
        var minY = Int.max
        var maxY = Int.min
        for py in (cy - half)...(cy + half) {
            for px in (cx - half)...(cx + half) where raster.luma(x: px, y: py) > threshold {
                minY = min(minY, py)
                maxY = max(maxY, py)
            }
        }
        return maxY >= minY ? maxY - minY : 0
    }
}

/// Writes events as newline-delimited JSON — the on-disk `events.jsonl` shape the renderer reads.
func writeEventsJSONL(_ events: [InputEvent], to url: URL) throws {
    let encoder = JSONEncoder()
    let lines = try events.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}
