import Foundation
import ZoomTypes

/// Tunables for automatic zoom-segment generation from an input-event stream.
public struct AutoZoomConfig: Sendable {
    public var clusterMaxGap: Double
    public var clusterMaxDistanceFrac: Double
    public var zoomScale: Double
    public var leadIn: Double
    public var holdPad: Double
    public var leadOut: Double
    public var mergeGap: Double
    public var minDuration: Double

    public init(
        clusterMaxGap: Double = 2.5,
        clusterMaxDistanceFrac: Double = 0.25,
        zoomScale: Double = 2.0,
        leadIn: Double = 0.8,
        holdPad: Double = 0.6,
        leadOut: Double = 1.0,
        mergeGap: Double = 1.5,
        minDuration: Double = 1.2
    ) {
        self.clusterMaxGap = clusterMaxGap
        self.clusterMaxDistanceFrac = clusterMaxDistanceFrac
        self.zoomScale = zoomScale
        self.leadIn = leadIn
        self.holdPad = holdPad
        self.leadOut = leadOut
        self.mergeGap = mergeGap
        self.minDuration = minDuration
    }
}

// Owned by the ZoomEngine packet — replace the stub body, keep the public API.
public enum AutoZoom {
    /// Generates zoom segments from captured input events (stub: none).
    public static func segments(
        from events: [InputEvent],
        width: Double,
        height: Double,
        config: AutoZoomConfig = AutoZoomConfig()
    ) -> [ZoomSegment] {
        []
    }
}
