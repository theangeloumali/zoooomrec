import AVFoundation
import Foundation
import RenderEngine
import XCTest
import ZoomTypes

final class ZoomRendererTests: XCTestCase {
    /// Renders a synthetic clip with an explicit zoom segment and asserts that the
    /// zoomed region actually changed the pixels mid-segment while leaving the
    /// pre-segment frame effectively untouched.
    func testRenderZoomsMidSegmentFrame() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoooomrec-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Build the .zoooomrec bundle: clip + manifest (explicit segments) + events.
        let bundleURL = workDir.appendingPathComponent("clip.zoooomrec")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let clip = SyntheticClip(width: 640, height: 360, fps: 24, durationSeconds: 2.0)
        let videoURL = bundleURL.appendingPathComponent(ZoooomrecBundle.videoName)
        try await clip.write(to: videoURL)

        let segment = ZoomSegment(start: 0.4, end: 1.6, centerX: 160, centerY: 180, scale: 2.0)
        let manifest = ProjectManifest(
            pixelWidth: 640,
            pixelHeight: 360,
            fps: 24,
            durationSeconds: 2.0,
            segments: [segment]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: bundleURL.appendingPathComponent(ZoooomrecBundle.manifestName))

        let events = [
            InputEvent(t: 0.5, kind: .move, x: 160, y: 180),
            InputEvent(t: 1.0, kind: .leftClick, x: 160, y: 180)
        ]
        try writeEvents(events, to: bundleURL.appendingPathComponent(ZoooomrecBundle.eventsName))

        // Render.
        let outputURL = workDir.appendingPathComponent("out.mp4")
        let progress = ProgressBox()
        let renderer = ZoomRenderer()
        try await renderer.render(projectBundle: bundleURL, outputURL: outputURL) { progress.set($0) }

        // Render completed, output exists, progress reached 1.0.
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(progress.value, 1.0, accuracy: 0.0001)

        // Duration within one frame; same pixel size.
        let inputAsset = AVURLAsset(url: videoURL)
        let outputAsset = AVURLAsset(url: outputURL)
        let inputDuration = try await inputAsset.load(.duration).seconds
        let outputDuration = try await outputAsset.load(.duration).seconds
        XCTAssertEqual(outputDuration, inputDuration, accuracy: 1.0 / 24.0 + 0.002)

        let outputTrack = try await outputAsset.loadTracks(withMediaType: .video).first
        let outputSize = try await XCTUnwrap(outputTrack).load(.naturalSize)
        XCTAssertEqual(Int(outputSize.width.rounded()), 640)
        XCTAssertEqual(Int(outputSize.height.rounded()), 360)

        // Frames for comparison.
        let inputFirst = try await frame(from: inputAsset, at: 0.0)
        let outputFirst = try await frame(from: outputAsset, at: 0.0)
        let inputMid = try await frame(from: inputAsset, at: 1.0)
        let outputMid = try await frame(from: outputAsset, at: 1.0)

        // Mid-segment: the bright square sat at this x in the input; the 2× zoom on the
        // left half moved it away, so the same coordinate is dark in the output.
        let sampleX = Int(clip.squareCenterX(atTime: 1.0).rounded())
        let sampleY = clip.height / 2
        XCTAssertGreaterThan(inputMid.luma(x: sampleX, y: sampleY), 180,
                             "input mid-frame should be bright where the square is")
        XCTAssertLessThan(outputMid.luma(x: sampleX, y: sampleY), 120,
                          "zoom should move the bright square away from this coordinate")

        // Pre-segment frame is near-identical; mid-segment changed more than the first.
        let firstDiff = outputFirst.meanAbsDiff(inputFirst)
        let midDiff = outputMid.meanAbsDiff(inputMid)
        XCTAssertLessThan(firstDiff, 12.0, "pre-segment frame should be near-identical to input")
        XCTAssertGreaterThan(midDiff, firstDiff, "zoom should change more pixels mid-segment than pre-segment")

        // Hand the rendered MP4 to the orchestrator.
        try copyToRecordings(outputURL)
    }

    // MARK: - Helpers

    private func writeEvents(_ events: [InputEvent], to url: URL) throws {
        let encoder = JSONEncoder()
        let lines = try events.map { event -> String in
            let data = try encoder.encode(event)
            return String(decoding: data, as: UTF8.self)
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyToRecordings(_ rendered: URL) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RenderEngineTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let recordings = repoRoot.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let destination = recordings.appendingPathComponent("zoom-smoke-synthetic.mp4")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: rendered, to: destination)
    }
}

/// Thread-safe container for the last reported progress fraction.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0

    var value: Double {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: Double) {
        lock.lock()
        stored = newValue
        lock.unlock()
    }
}
