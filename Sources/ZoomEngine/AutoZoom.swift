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

public enum AutoZoom {
    /// Generates zoom segments from captured input events.
    ///
    /// Clicks are grouped into clusters (bounded by `clusterMaxGap` in time and
    /// `clusterMaxDistanceFrac × width` in space); `key_down` events extend the
    /// active cluster's hold without moving its centroid. Each cluster becomes a
    /// padded segment; segments closer than `mergeGap` merge (killing "zoom
    /// pumping") with a click-count-weighted centroid; anything shorter than
    /// `minDuration` is dropped. Output is sorted by start and non-overlapping.
    public static func segments(
        from events: [InputEvent],
        width: Double,
        height: Double,
        config: AutoZoomConfig = AutoZoomConfig()
    ) -> [ZoomSegment] {
        let ordered = events
            .filter { $0.kind == .leftClick || $0.kind == .rightClick || $0.kind == .keyDown }
            .sorted { $0.t < $1.t }

        let maxDistance = config.clusterMaxDistanceFrac * width

        // 1. Cluster.
        var clusters: [RawCluster] = []
        var open: RawCluster?

        for event in ordered {
            let isClick = event.kind == .leftClick || event.kind == .rightClick
            if isClick {
                if var current = open, current.accepts(click: event, maxGap: config.clusterMaxGap, maxDistance: maxDistance) {
                    current.addClick(event)
                    open = current
                } else {
                    if let current = open { clusters.append(current) }
                    open = RawCluster(click: event)
                }
            } else if var current = open, event.t - current.lastEventT <= config.clusterMaxGap {
                // key_down extends the hold but leaves the centroid untouched.
                current.extend(to: event.t)
                open = current
            }
        }
        if let current = open { clusters.append(current) }

        // 2. Pad into segments, then merge anything closer than mergeGap.
        var merged: [PaddedSegment] = []
        for cluster in clusters.map({ $0.padded(config: config) }).sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, cluster.start - last.end < config.mergeGap {
                last.merge(cluster)
                merged[merged.count - 1] = last
            } else {
                merged.append(cluster)
            }
        }

        // 3. Drop short segments, emit sorted ZoomSegments.
        return merged
            .filter { $0.end - $0.start >= config.minDuration }
            .map { $0.segment }
    }
}

/// A forming click cluster: click coordinates plus the running hold end.
private struct RawCluster {
    var firstClickT: Double
    var lastEventT: Double
    var lastClickT: Double
    var lastClickX: Double
    var lastClickY: Double
    var sumX: Double
    var sumY: Double
    var clickCount: Int

    init(click event: InputEvent) {
        firstClickT = event.t
        lastEventT = event.t
        lastClickT = event.t
        lastClickX = event.x
        lastClickY = event.y
        sumX = event.x
        sumY = event.y
        clickCount = 1
    }

    func accepts(click event: InputEvent, maxGap: Double, maxDistance: Double) -> Bool {
        let dx = event.x - lastClickX
        let dy = event.y - lastClickY
        let distance = (dx * dx + dy * dy).squareRoot()
        return event.t - lastClickT <= maxGap && distance <= maxDistance
    }

    mutating func addClick(_ event: InputEvent) {
        sumX += event.x
        sumY += event.y
        clickCount += 1
        lastClickT = event.t
        lastClickX = event.x
        lastClickY = event.y
        lastEventT = event.t
    }

    // Events arrive time-sorted, so extension times are monotonic.
    mutating func extend(to time: Double) {
        lastEventT = time
    }

    func padded(config: AutoZoomConfig) -> PaddedSegment {
        PaddedSegment(
            start: max(0, firstClickT - config.leadIn),
            end: lastEventT + config.holdPad + config.leadOut,
            sumX: sumX,
            sumY: sumY,
            clickCount: clickCount,
            scale: config.zoomScale)
    }
}

/// A padded segment carrying enough state to merge with click-count weighting.
private struct PaddedSegment {
    var start: Double
    var end: Double
    var sumX: Double
    var sumY: Double
    var clickCount: Int
    var scale: Double

    mutating func merge(_ other: PaddedSegment) {
        start = min(start, other.start)
        end = max(end, other.end)
        sumX += other.sumX
        sumY += other.sumY
        clickCount += other.clickCount
        scale = max(scale, other.scale)
    }

    var segment: ZoomSegment {
        ZoomSegment(
            start: start,
            end: end,
            centerX: sumX / Double(clickCount),
            centerY: sumY / Double(clickCount),
            scale: scale)
    }
}
