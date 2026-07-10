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
        /// Live hotkey zoom markers captured during recording. `zoomIn` opens a
        /// manual zoom at the cursor position; `zoomOut` closes the active zoom.
        case zoomIn = "zoom_in"
        case zoomOut = "zoom_out"
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

/// An axis-aligned rectangle in capture-space pixels, top-left origin.
///
/// Deliberately *not* `CGRect`: `ZoomTypes` and `ZoomEngine` must stay free of every
/// platform framework so the timeline and zoom math port to Android and Windows
/// unchanged. Platform layers bridge this at their own boundary.
public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// Per-frame crop rectangle in capture-space pixels (top-left origin).
///
/// Derived at render time from the zoom timeline and **never persisted** — storing it
/// would freeze the animation and prevent re-rendering with a different spring feel.
public struct CropKeyframe: Equatable, Sendable {
    public var t: Double
    public var rect: Rect

    public init(t: Double, rect: Rect) {
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
    /// Zoom magnification chosen at record time (applied to hotkey/auto zooms at
    /// render). `nil` means the renderer uses its own default. Additive/optional.
    public var zoomScale: Double?

    public init(
        version: Int = 1,
        videoFile: String = ZoooomrecBundle.videoName,
        eventsFile: String = ZoooomrecBundle.eventsName,
        pixelWidth: Int,
        pixelHeight: Int,
        fps: Double,
        durationSeconds: Double,
        segments: [ZoomSegment]? = nil,
        zoomScale: Double? = nil
    ) {
        self.version = version
        self.videoFile = videoFile
        self.eventsFile = eventsFile
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.durationSeconds = durationSeconds
        self.segments = segments
        self.zoomScale = zoomScale
    }
}

/// Canonical file names inside a `.zoooomrec` bundle directory.
public enum ZoooomrecBundle {
    public static let videoName = "recording.mp4"
    public static let eventsName = "events.jsonl"
    public static let manifestName = "project.json"
}

/// Shared zoom defaults so the record-time default and the render fallback stay in lockstep.
public enum ZoomDefaults {
    /// Default zoom magnification (2× — legible without disorienting).
    public static let scale = 2.0
}
