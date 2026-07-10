import Foundation
import ZoomEngine
import ZoomTypes

/// Everything the editor reads out of a `.zoooomrec` bundle.
///
/// Mirrors what `RenderEngine.RenderBundle` consumes, but lives in the app layer because
/// that reader is internal to `RenderEngine`. It never mutates the bundle — the editor only
/// writes back through `project.json` at save time.
struct EditorBundle {
    let manifest: ProjectManifest
    let events: [InputEvent]
    let videoURL: URL

    enum LoadError: LocalizedError {
        case missingManifest(URL)
        case unreadableManifest(URL)
        case missingVideo(URL)

        var errorDescription: String? {
            switch self {
            case .missingManifest(let url):
                return "No project.json found in this bundle (\(url.lastPathComponent))."
            case .unreadableManifest(let url):
                return "project.json could not be read — it may be corrupt (\(url.lastPathComponent))."
            case .missingVideo(let url):
                return "The recording video is missing (\(url.lastPathComponent))."
            }
        }
    }

    init(bundleURL: URL) throws {
        let fileManager = FileManager.default

        let manifestURL = bundleURL.appendingPathComponent(ZoooomrecBundle.manifestName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw LoadError.missingManifest(manifestURL)
        }
        do {
            manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw LoadError.unreadableManifest(manifestURL)
        }

        let videoURL = bundleURL.appendingPathComponent(manifest.videoFile)
        guard fileManager.fileExists(atPath: videoURL.path) else {
            throw LoadError.missingVideo(videoURL)
        }
        self.videoURL = videoURL
        self.events = EditorBundle.readEvents(at: bundleURL.appendingPathComponent(manifest.eventsFile))
    }

    /// Seeds the editable segment list so the editor opens showing what the video actually does:
    /// explicit `manifest.segments` win, else derive from the event stream exactly as
    /// `ZoomRenderer` does — hotkey markers (`zoom_in`) → `ManualZoom`, else click `AutoZoom`.
    func initialSegments() -> [ZoomSegment] {
        if let explicit = manifest.segments {
            return explicit
        }
        let width = Double(manifest.pixelWidth)
        let height = Double(manifest.pixelHeight)
        if events.contains(where: { $0.kind == .zoomIn }) {
            return ManualZoom.segments(
                from: events,
                width: width,
                height: height,
                scale: manifest.zoomScale ?? ZoomDefaults.scale,
                duration: manifest.durationSeconds)
        }
        return AutoZoom.segments(from: events, width: width, height: height)
    }

    /// Parses newline-delimited JSON events; tolerates a missing, empty, or partly-corrupt file
    /// (unknown/undecodable lines are skipped, matching the bundle's forward-compatibility rule).
    private static func readEvents(at url: URL) -> [InputEvent] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        var events: [InputEvent] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let event = try? decoder.decode(InputEvent.self, from: lineData) else {
                continue
            }
            events.append(event)
        }
        return events
    }
}
