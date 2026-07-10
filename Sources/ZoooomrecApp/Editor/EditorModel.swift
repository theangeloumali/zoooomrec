import AppKit
import AVFoundation
import Combine
import Foundation
import RenderEngine
import ZoomEngine
import ZoomTypes

/// State and behaviour for one editor window: the editable segment list, playhead, trim
/// range, live preview, and the save-and-re-render pipeline.
///
/// `@unchecked Sendable`, following `MenuBarController`'s convention: every stored property is
/// touched only on the main thread. Frame generation and rendering run off-main and marshal
/// every UI mutation back through `DispatchQueue.main.async`.
final class EditorModel: ObservableObject, @unchecked Sendable {
    let bundleURL: URL

    // Immutable loaded context.
    private let bundle: EditorBundle?
    private let frameProvider: FrameProvider?
    private let onRendered: ((URL) -> Void)?
    let width: Double
    let height: Double
    let fps: Double
    let duration: Double

    @Published private(set) var errorMessage: String?
    @Published var segments: [EditableSegment] = []
    @Published var selectedID: UUID?
    @Published private(set) var playhead: Double = 0
    @Published private(set) var trimStart: Double = 0
    @Published private(set) var trimEnd: Double = 0
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var isRendering = false
    @Published private(set) var renderProgress: Double = 0
    @Published private(set) var renderedURL: URL?

    /// Cached crop rects for the whole timeline (one per output frame), recomputed only when
    /// segments change. Scrubbing just re-indexes this — it does not re-run the spring.
    private var keyframes: [CropKeyframe] = []

    var isLoaded: Bool { bundle != nil }

    init(bundleURL: URL, onRendered: ((URL) -> Void)?) {
        self.bundleURL = bundleURL
        self.onRendered = onRendered
        do {
            let bundle = try EditorBundle(bundleURL: bundleURL)
            self.bundle = bundle
            self.width = Double(bundle.manifest.pixelWidth)
            self.height = Double(bundle.manifest.pixelHeight)
            self.fps = bundle.manifest.fps
            self.duration = bundle.manifest.durationSeconds
            self.frameProvider = FrameProvider(
                asset: AVURLAsset(url: bundle.videoURL),
                manifestSize: CGSize(width: Double(bundle.manifest.pixelWidth), height: Double(bundle.manifest.pixelHeight)))
            self.trimEnd = bundle.manifest.durationSeconds
            self.segments = SegmentOps.sorted(bundle.initialSegments().map { EditableSegment($0) })
            recomputeKeyframes()
            refreshPreview()
        } catch {
            self.bundle = nil
            self.frameProvider = nil
            self.width = 0
            self.height = 0
            self.fps = 0
            self.duration = 0
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Derived

    var selectedSegment: EditableSegment? {
        guard let selectedID else { return nil }
        return segments.first { $0.id == selectedID }
    }

    /// The crop rect the renderer would use at the current playhead — makes the preview
    /// WYSIWYG. Outside any zoom this is (approximately) the full frame, so focus edits can
    /// still target the whole image.
    var currentCrop: Rect? {
        guard !keyframes.isEmpty, fps > 0 else { return nil }
        let index = Int((playhead * fps).rounded())
        return keyframes[min(max(0, index), keyframes.count - 1)].rect
    }

    // MARK: - Preview

    private func recomputeKeyframes() {
        guard let bundle, duration > 0, fps > 0 else {
            keyframes = []
            return
        }
        keyframes = ZoomTimeline.cropKeyframes(
            segments: segments.map(\.segment),
            events: bundle.events,
            width: width,
            height: height,
            fps: fps,
            duration: duration)
    }

    private func refreshPreview() {
        frameProvider?.requestFrame(atTime: playhead, crop: currentCrop) { [weak self] image in
            guard let self, let image else { return }
            self.previewImage = image
        }
    }

    private func segmentsDidChange() {
        recomputeKeyframes()
        refreshPreview()
    }

    // MARK: - Playhead & trim

    func scrub(to time: Double) {
        playhead = min(max(0, time), duration)
        refreshPreview()
    }

    func setTrimStart(_ time: Double) {
        trimStart = min(max(0, time), max(0, trimEnd - SegmentOps.minDuration))
        if playhead < trimStart { scrub(to: trimStart) }
    }

    func setTrimEnd(_ time: Double) {
        trimEnd = max(min(duration, time), min(duration, trimStart + SegmentOps.minDuration))
        if playhead > trimEnd { scrub(to: trimEnd) }
    }

    // MARK: - Segment edits

    func select(_ id: UUID?) {
        selectedID = id
    }

    func addZoomAtPlayhead() {
        let result = SegmentOps.insert(
            segments,
            atPlayhead: playhead,
            duration: duration,
            center: (x: width / 2, y: height / 2),
            scale: ZoomDefaults.scale)
        guard let newID = result.id else { return }
        segments = result.items
        selectedID = newID
        segmentsDidChange()
    }

    func deleteSelected() {
        guard let selectedID else { return }
        segments.removeAll { $0.id == selectedID }
        self.selectedID = nil
        segmentsDidChange()
    }

    func move(id: UUID, toStart newStart: Double) {
        segments = SegmentOps.move(segments, id: id, toStart: newStart, duration: duration)
        segmentsDidChange()
    }

    func resizeStart(id: UUID, to newStart: Double) {
        segments = SegmentOps.resizeStart(segments, id: id, to: newStart, duration: duration)
        segmentsDidChange()
    }

    func resizeEnd(id: UUID, to newEnd: Double) {
        segments = SegmentOps.resizeEnd(segments, id: id, to: newEnd, duration: duration)
        segmentsDidChange()
    }

    func setSelectedScale(_ scale: Double) {
        updateSelected { $0.scale = min(max(1.0, scale), 4.0) }
    }

    func setSelectedCenter(x: Double, y: Double) {
        updateSelected {
            $0.centerX = min(max(0, x), width)
            $0.centerY = min(max(0, y), height)
        }
    }

    private func updateSelected(_ transform: (inout ZoomSegment) -> Void) {
        guard let selectedID, let index = segments.firstIndex(where: { $0.id == selectedID }) else { return }
        transform(&segments[index].segment)
        segmentsDidChange()
    }

    // MARK: - Save & render

    func clearError() {
        guard isLoaded else { return }
        errorMessage = nil
    }

    /// Writes the edited segments (clamped into the trim range) back into `project.json`,
    /// preserving every other manifest field, then re-renders the sibling `<name>.mp4`.
    func saveAndRender() {
        guard let bundle, !isRendering else { return }
        isRendering = true
        renderProgress = 0
        renderedURL = nil
        errorMessage = nil

        var manifest = bundle.manifest
        manifest.segments = SegmentOps.clampedToTrim(segments, trimStart: trimStart, trimEnd: trimEnd)

        let manifestURL = bundleURL.appendingPathComponent(ZoooomrecBundle.manifestName)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            isRendering = false
            errorMessage = "Could not save project.json: \(error.localizedDescription)"
            return
        }

        // A strong capture is deliberate: the render should run to completion (and fire
        // `onRendered`) even if the window closes mid-render. There is no retain cycle — the
        // Task is not stored, so `self` is released when the Task finishes. `EditorModel` is
        // `@unchecked Sendable`, so the crossings into the `@Sendable` closures are safe.
        let outputURL = bundleURL.deletingPathExtension().appendingPathExtension("mp4")
        let renderer = ZoomRenderer()
        let bundleURL = bundleURL
        Task {
            do {
                try await renderer.render(projectBundle: bundleURL, outputURL: outputURL) { fraction in
                    DispatchQueue.main.async { self.renderProgress = fraction }
                }
                DispatchQueue.main.async { self.didFinishRender(outputURL) }
            } catch {
                DispatchQueue.main.async { self.renderFailed(error) }
            }
        }
    }

    private func didFinishRender(_ url: URL) {
        isRendering = false
        renderProgress = 1
        renderedURL = url
        onRendered?(url)
    }

    private func renderFailed(_ error: Error) {
        isRendering = false
        errorMessage = "Render failed: \(error.localizedDescription)"
    }
}
