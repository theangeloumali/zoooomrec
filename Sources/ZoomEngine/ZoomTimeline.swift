import CoreGraphics
import Foundation
import ZoomTypes

/// Spring parameters for zoom animation (critically damped).
public struct SpringConfig: Sendable {
    /// Angular frequency for the attack (zoom-in) and all pan motion; higher = snappier.
    /// ~4.2 gives a ≈1s glide — the Screen Studio "soft landing" feel.
    public var omega: Double

    /// Angular frequency for the release (zoom-out relaxing back). Lower than `omega`
    /// so the view eases OUT more slowly than it snapped in — the Screen Studio signature.
    public var releaseOmega: Double

    public init(omega: Double = 4.2, releaseOmega: Double = 3.2) {
        self.omega = omega
        self.releaseOmega = releaseOmega
    }
}

public enum ZoomTimeline {
    /// Compiles zoom segments into one crop rectangle per output frame.
    ///
    /// State `(centerX, centerY, scale)` is integrated frame by frame with a
    /// critically damped spring toward the active segment's target (or the full
    /// frame outside any segment). The scale spring eases IN with `spring.omega`
    /// and OUT with the slower `spring.releaseOmega`; center springs always use
    /// `spring.omega`. The crop rect is recomputed and clamped fully inside
    /// `(0, 0, width, height)` AFTER integration each frame. Rects are
    /// capture-space pixels, top-left origin.
    public static func cropKeyframes(
        segments: [ZoomSegment],
        width: Double,
        height: Double,
        fps: Double,
        duration: Double,
        spring: SpringConfig = SpringConfig()
    ) -> [CropKeyframe] {
        simulate(
            segments: segments, moves: [],
            width: width, height: height, fps: fps, duration: duration, spring: spring)
    }

    /// Cursor-following overload: identical spring simulation, except inside an active
    /// segment the target CENTER tracks the live cursor (the nearest `.move` event with
    /// `t ≤ frame t`, carried forward) instead of the segment's fixed center. A dead-zone
    /// suppresses jitter — the target only retargets to the cursor when the cursor leaves
    /// the inner ~70% of the current crop rect. Outside any segment the target is the full
    /// frame. The followed center is clamped so the crop at the segment's scale stays in frame.
    public static func cropKeyframes(
        segments: [ZoomSegment],
        events: [InputEvent],
        width: Double,
        height: Double,
        fps: Double,
        duration: Double,
        spring: SpringConfig = SpringConfig()
    ) -> [CropKeyframe] {
        let moves = events.filter { $0.kind == .move }.sorted { $0.t < $1.t }
        return simulate(
            segments: segments, moves: moves,
            width: width, height: height, fps: fps, duration: duration, spring: spring)
    }

    /// Fraction of the crop the cursor may roam inside before the follow target moves.
    private static let deadZoneFraction = 0.7

    /// Shared spring integrator for both overloads. `moves` is the time-sorted cursor
    /// track (empty for the fixed-center overload, which then reproduces the classic behavior).
    private static func simulate(
        segments: [ZoomSegment],
        moves: [InputEvent],
        width: Double,
        height: Double,
        fps: Double,
        duration: Double,
        spring: SpringConfig
    ) -> [CropKeyframe] {
        let frameCount = max(0, Int((duration * fps).rounded(.up)))
        guard frameCount > 0, fps > 0 else { return [] }

        let dt = 1.0 / fps
        let omega = spring.omega
        let releaseOmega = spring.releaseOmega
        // Critical damping cannot overshoot the target, but a large mid-flight
        // velocity can; clamp scale defensively to [1, maxTargetScale].
        let maxScale = max(1.0, segments.map(\.scale).max() ?? 1.0)

        var centerX = SpringState(value: width / 2)
        var centerY = SpringState(value: height / 2)
        var scale = SpringState(value: 1.0)

        // Carried-forward cursor position (nil until the first move).
        var moveIndex = 0
        var cursorX: Double?
        var cursorY: Double?
        // Committed follow target within the active segment; reseeded on segment entry.
        var followX = width / 2
        var followY = height / 2
        var activeStart: Double?

        var frames: [CropKeyframe] = []
        frames.reserveCapacity(frameCount)

        for index in 0..<frameCount {
            let t = Double(index) / fps

            // Advance the cursor to the latest move at or before this frame.
            while moveIndex < moves.count, moves[moveIndex].t <= t {
                cursorX = moves[moveIndex].x
                cursorY = moves[moveIndex].y
                moveIndex += 1
            }

            let target = segments.first { t >= $0.start && t <= $0.end }
            let targetScale = max(1.0, target?.scale ?? 1.0)

            // Pick the pre-clamp target center: cursor-follow inside a segment, else full frame.
            let baseX: Double
            let baseY: Double
            if let segment = target {
                if activeStart != segment.start {
                    // New segment: seed the follow target at its click/centroid center.
                    activeStart = segment.start
                    followX = segment.centerX
                    followY = segment.centerY
                }
                if let cursorX, let cursorY {
                    // Retarget only when the cursor leaves the inner dead-zone of the live crop.
                    let cropWidth = width / scale.value
                    let cropHeight = height / scale.value
                    let innerHalfWidth = cropWidth * deadZoneFraction / 2
                    let innerHalfHeight = cropHeight * deadZoneFraction / 2
                    if abs(cursorX - centerX.value) > innerHalfWidth
                        || abs(cursorY - centerY.value) > innerHalfHeight {
                        followX = cursorX
                        followY = cursorY
                    }
                }
                baseX = followX
                baseY = followY
            } else {
                activeStart = nil
                baseX = width / 2
                baseY = height / 2
            }

            // Clamp the TARGET center so the crop at target scale stays in frame —
            // otherwise the spring chases an unreachable point and edge zooms exit
            // with a lag while hidden state travels back. Output clamp below stays
            // as a safety net for mid-flight states.
            let halfWidth = width / targetScale / 2
            let halfHeight = height / targetScale / 2
            let targetX = min(max(halfWidth, baseX), width - halfWidth)
            let targetY = min(max(halfHeight, baseY), height - halfHeight)

            if index > 0 {
                // Ease in fast, relax out slow: release when the target sits below the
                // current scale (zoom-out), attack otherwise.
                let scaleOmega = targetScale >= scale.value ? omega : releaseOmega
                centerX.integrate(toward: targetX, omega: omega, dt: dt)
                centerY.integrate(toward: targetY, omega: omega, dt: dt)
                scale.integrate(toward: targetScale, omega: scaleOmega, dt: dt)
                scale.clamp(to: 1.0, and: maxScale)
            }

            let cropWidth = width / scale.value
            let cropHeight = height / scale.value
            let x = min(max(0, centerX.value - cropWidth / 2), width - cropWidth)
            let y = min(max(0, centerY.value - cropHeight / 2), height - cropHeight)
            frames.append(CropKeyframe(t: t, rect: CGRect(x: x, y: y, width: cropWidth, height: cropHeight)))
        }
        return frames
    }
}

/// One scalar under a critically damped spring, integrated by its exact flow map.
private struct SpringState {
    var value: Double
    var velocity: Double = 0

    /// Closed-form critically damped step (exact for a constant target):
    /// `y'' + 2ω y' + ω² y = 0`, `y = x − target`, `y(t) = (A + Bt)e^{−ωt}`.
    mutating func integrate(toward target: Double, omega: Double, dt: Double) {
        let y0 = value - target
        let b = velocity + omega * y0
        let decay = exp(-omega * dt)
        value = target + (y0 + b * dt) * decay
        velocity = (velocity - omega * b * dt) * decay
    }

    mutating func clamp(to lower: Double, and upper: Double) {
        if value < lower {
            value = lower
            velocity = 0
        } else if value > upper {
            value = upper
            velocity = 0
        }
    }
}
