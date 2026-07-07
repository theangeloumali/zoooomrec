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

// Owned by the ZoomEngine packet — replace the linear-ramp stub with the
// critically damped spring integrator, keep the public API.
public enum ZoomTimeline {
    /// Compiles zoom segments into one crop rectangle per output frame.
    /// Rects are capture-space pixels, top-left origin, always clamped in bounds.
    public static func cropKeyframes(
        segments: [ZoomSegment],
        width: Double,
        height: Double,
        fps: Double,
        duration: Double,
        spring: SpringConfig = SpringConfig()
    ) -> [CropKeyframe] {
        let frameCount = max(0, Int((duration * fps).rounded(.up)))
        let ramp = 0.5
        var frames: [CropKeyframe] = []
        frames.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            let t = Double(index) / fps
            var centerX = width / 2
            var centerY = height / 2
            var scale = 1.0
            if let segment = segments.first(where: { t >= $0.start && t <= $0.end }) {
                let rampIn = min(1, max(0, (t - segment.start) / ramp))
                let rampOut = min(1, max(0, (segment.end - t) / ramp))
                let progress = min(rampIn, rampOut)
                scale = 1 + (segment.scale - 1) * progress
                centerX += (segment.centerX - centerX) * progress
                centerY += (segment.centerY - centerY) * progress
            }
            let cropWidth = width / scale
            let cropHeight = height / scale
            let x = min(max(0, centerX - cropWidth / 2), width - cropWidth)
            let y = min(max(0, centerY - cropHeight / 2), height - cropHeight)
            frames.append(CropKeyframe(t: t, rect: CGRect(x: x, y: y, width: cropWidth, height: cropHeight)))
        }
        return frames
    }
}
