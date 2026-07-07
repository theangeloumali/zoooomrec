import Foundation
import ZoomTypes

/// Errors surfaced while rendering a `.zoooomrec` bundle.
public enum RenderError: Error, CustomStringConvertible {
    case missingManifest(URL)
    case missingVideo(URL)
    case noVideoTrack(URL)
    case readerSetupFailed
    case writerSetupFailed
    case pixelBufferPoolUnavailable
    case pixelBufferAllocationFailed(OSStatus)
    case appendFailed

    public var description: String {
        switch self {
        case .missingManifest(let url): return "missing project.json at \(url.path)"
        case .missingVideo(let url): return "missing video file at \(url.path)"
        case .noVideoTrack(let url): return "no video track in \(url.path)"
        case .readerSetupFailed: return "failed to set up the AVAssetReader"
        case .writerSetupFailed: return "failed to set up the AVAssetWriter"
        case .pixelBufferPoolUnavailable: return "writer pixel-buffer pool was unavailable"
        case .pixelBufferAllocationFailed(let status): return "pixel-buffer allocation failed (status \(status))"
        case .appendFailed: return "the writer rejected an appended frame"
        }
    }
}

/// Reads the contents of a `.zoooomrec` bundle directory needed for rendering.
struct RenderBundle {
    let manifest: ProjectManifest
    let events: [InputEvent]
    let videoURL: URL

    init(bundle: URL) throws {
        let fileManager = FileManager.default

        let manifestURL = bundle.appendingPathComponent(ZoooomrecBundle.manifestName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw RenderError.missingManifest(manifestURL)
        }
        manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))

        let videoURL = bundle.appendingPathComponent(manifest.videoFile)
        guard fileManager.fileExists(atPath: videoURL.path) else {
            throw RenderError.missingVideo(videoURL)
        }
        self.videoURL = videoURL

        let eventsURL = bundle.appendingPathComponent(manifest.eventsFile)
        events = RenderBundle.readEvents(at: eventsURL)
    }

    /// Parses newline-delimited JSON events; tolerates a missing or empty file.
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
