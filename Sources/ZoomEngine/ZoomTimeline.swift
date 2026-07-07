import CoreGraphics
import Foundation
import ZoomTypes

/// Spring parameters for zoom animation (critically damped).
public struct SpringConfig: Sendable {
    /// Angular frequency; higher = snappier.
    public var omega: Double

    public init(omega: Double = 8.0) {
        self.omega = omega
    }
}

public enum ZoomTimeline {
    /// Compiles zoom segments into one crop rectangle per output frame.
    ///
    /// State `(centerX, centerY, scale)` is integrated frame by frame with a
    /// critically damped spring toward the active segment's target (or the full
    /// frame outside any segment). The crop rect is recomputed and clamped fully
    /// inside `(0, 0, width, height)` AFTER integration each frame. Rects are
    /// capture-space pixels, top-left origin.
    public static func cropKeyframes(
        segments: [ZoomSegment],
        width: Double,
        height: Double,
        fps: Double,
        duration: Double,
        spring: SpringConfig = SpringConfig()
    ) -> [CropKeyframe] {
        let frameCount = max(0, Int((duration * fps).rounded(.up)))
        guard frameCount > 0, fps > 0 else { return [] }

        let dt = 1.0 / fps
        let omega = spring.omega
        // Critical damping cannot overshoot the target, but a large mid-flight
        // velocity can; clamp scale defensively to [1, maxTargetScale].
        let maxScale = max(1.0, segments.map(\.scale).max() ?? 1.0)

        var centerX = SpringState(value: width / 2)
        var centerY = SpringState(value: height / 2)
        var scale = SpringState(value: 1.0)

        var frames: [CropKeyframe] = []
        frames.reserveCapacity(frameCount)

        for index in 0..<frameCount {
            let t = Double(index) / fps
            let target = segments.first { t >= $0.start && t <= $0.end }
            let targetScale = max(1.0, target?.scale ?? 1.0)
            // Clamp the TARGET center so the crop at target scale stays in frame —
            // otherwise the spring chases an unreachable point and edge zooms exit
            // with a lag while hidden state travels back. Output clamp below stays
            // as a safety net for mid-flight states.
            let halfWidth = width / targetScale / 2
            let halfHeight = height / targetScale / 2
            let targetX = min(max(halfWidth, target?.centerX ?? width / 2), width - halfWidth)
            let targetY = min(max(halfHeight, target?.centerY ?? height / 2), height - halfHeight)

            if index > 0 {
                centerX.integrate(toward: targetX, omega: omega, dt: dt)
                centerY.integrate(toward: targetY, omega: omega, dt: dt)
                scale.integrate(toward: targetScale, omega: omega, dt: dt)
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
