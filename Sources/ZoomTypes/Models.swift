import CoreGraphics
import Foundation

/// One captured input event. Timestamps are seconds since the first video frame.
/// Coordinates are capture-space pixels with a TOP-LEFT origin.
public struct InputEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case move
        case leftClick = "left_click"
        case rightClick = "right_click"
        case scroll
        case keyDown = "key_down"
    }

    public var t: Double
    public var kind: Kind
    public var x: Double
    public var y: Double

    public init(t: Double, kind: Kind, x: Double, y: Double) {
        self.t = t
        self.kind = kind
        self.x = x
        self.y = y
    }
}

/// A zoom segment on the timeline: zoom toward (centerX, centerY) at `scale` between `start` and `end` seconds.
public struct ZoomSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var centerX: Double
    public var centerY: Double
    public var scale: Double

    public init(start: Double, end: Double, centerX: Double, centerY: Double, scale: Double) {
        self.start = start
        self.end = end
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
    }
}

/// Per-frame crop rectangle in capture-space pixels (top-left origin).
public struct CropKeyframe: Equatable, Sendable {
    public var t: Double
    public var rect: CGRect

    public init(t: Double, rect: CGRect) {
        self.t = t
        self.rect = rect
    }
}

/// The `project.json` manifest inside a `.zoooomrec` bundle directory.
public struct ProjectManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var videoFile: String
    public var eventsFile: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fps: Double
    public var durationSeconds: Double
    /// Explicit zoom edits. `nil` means "auto-generate from the event stream".
    public var segments: [ZoomSegment]?

    public init(
        version: Int = 1,
        videoFile: String = ZoooomrecBundle.videoName,
        eventsFile: String = ZoooomrecBundle.eventsName,
        pixelWidth: Int,
        pixelHeight: Int,
        fps: Double,
        durationSeconds: Double,
        segments: [ZoomSegment]? = nil
    ) {
        self.version = version
        self.videoFile = videoFile
        self.eventsFile = eventsFile
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.durationSeconds = durationSeconds
        self.segments = segments
    }
}

/// Canonical file names inside a `.zoooomrec` bundle directory.
public enum ZoooomrecBundle {
    public static let videoName = "recording.mp4"
    public static let eventsName = "events.jsonl"
    public static let manifestName = "project.json"
}
