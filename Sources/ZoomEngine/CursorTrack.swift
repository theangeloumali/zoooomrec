import ZoomTypes

/// Tunables for the synthetic-cursor render track (ZR-102).
///
/// The raw `move` samples stay the source of truth; these knobs only shape how the
/// cursor is *presented*: how sensitive "is it moving?" is, and the idle/fade timing
/// of hide-when-static. All time values are seconds; distances are capture-space pixels.
public struct CursorConfig: Sendable {
    /// Pointer must move at least this many px (from where it last settled) to count as "moving".
    public var idleEpsilonPixels: Double
    /// Stationary for this long ⇒ the cursor has fully begun (and, after `fadeSeconds`, finished) hiding.
    public var idleSeconds: Double
    /// Seconds spent fading out once idle — and, symmetrically, fading back in on movement resume.
    public var fadeSeconds: Double

    public init(idleEpsilonPixels: Double = 2.0, idleSeconds: Double = 2.0, fadeSeconds: Double = 0.35) {
        self.idleEpsilonPixels = idleEpsilonPixels
        self.idleSeconds = idleSeconds
        self.fadeSeconds = fadeSeconds
    }
}

/// Smoothed synthetic cursor derived from the raw `move` track (ZR-102).
///
/// Position is a **time-parametrised** Catmull-Rom spline through the four samples
/// surrounding `t` (never index-parametrised — `move` intervals are ~60 Hz but not
/// uniform). Opacity is a slew-rate-limited hide-when-static signal: full while moving,
/// ramps to 0 after `idleSeconds` of stillness over `fadeSeconds`, and climbs back to 1
/// over `fadeSeconds` when motion resumes. Both are pure functions of the track, so the
/// renderer can re-smooth or re-style at will — nothing here is persisted.
public enum CursorTrack {
    /// Smoothed cursor position + opacity at time `t`, or `nil` when the track is empty
    /// or `t` precedes the first sample. After the last sample the position holds.
    public static func frame(at t: Double, moves: [InputEvent], config: CursorConfig = CursorConfig()) -> CursorFrame? {
        guard let track = Track(moves: moves, config: config) else { return nil }
        var segmentHint = 0
        var breakpointHint = 0
        return track.frame(at: t, segmentHint: &segmentHint, breakpointHint: &breakpointHint)
    }

    /// One `CursorFrame?` per output frame at `t = j / fps` (`j` in `0..<ceil(duration*fps)`),
    /// for the renderer's per-frame loop. `nil` entries are frames before the first sample.
    ///
    /// O(frames + moves): the track is built once and the per-frame lookup advances forward
    /// indices instead of rescanning `moves`. Produces values identical to `frame(at:)` — the
    /// underlying math is one shared routine; the indices only pick where to start the search.
    public static func frames(moves: [InputEvent], fps: Double, duration: Double, config: CursorConfig = CursorConfig()) -> [CursorFrame?] {
        let frameCount = max(0, Int((duration * fps).rounded(.up)))
        guard frameCount > 0, fps > 0 else { return [] }

        guard let track = Track(moves: moves, config: config) else {
            return [CursorFrame?](repeating: nil, count: frameCount)
        }

        var result: [CursorFrame?] = []
        result.reserveCapacity(frameCount)
        var segmentHint = 0
        var breakpointHint = 0
        for index in 0..<frameCount {
            let t = Double(index) / fps
            result.append(track.frame(at: t, segmentHint: &segmentHint, breakpointHint: &breakpointHint))
        }
        return result
    }
}

/// Precomputed, time-sorted cursor track. Splits the two concerns cleanly:
/// - **position**: Catmull-Rom over `times`/`points`, evaluated by bracketing `t`.
/// - **opacity**: a piecewise-linear slew signal sampled at precomputed breakpoints.
///
/// Both `frame(at:)` and `frames(...)` drive this same instance, so their outputs match
/// exactly; the `inout` hints let the per-frame sweep stay O(1) amortised without changing
/// the arithmetic a fresh lookup would perform.
private struct Track {
    private let times: [Double]
    private let points: [Point]

    /// Times at which the opacity target changes; `target[k]` holds from `breakpointTimes[k]`
    /// until the next breakpoint, and `opacityAtBreakpoint[k]` is the exact opacity there.
    private let breakpointTimes: [Double]
    private let breakpointTargets: [Double]
    private let opacityAtBreakpoint: [Double]
    private let fadeSeconds: Double

    init?(moves: [InputEvent], config: CursorConfig) {
        let sorted = moves.filter { $0.kind == .move }.sorted { $0.t < $1.t }
        guard let first = sorted.first else { return nil }

        times = sorted.map(\.t)
        points = sorted.map { Point(x: $0.x, y: $0.y) }
        fadeSeconds = config.fadeSeconds

        // Motion times: the first sample (appearance), plus each sample that leaves the
        // idle epsilon of where the pointer last settled. Idle is measured from the most
        // recent motion time, so a sample within epsilon extends stillness rather than
        // resetting it.
        let epsilonSquared = config.idleEpsilonPixels * config.idleEpsilonPixels
        var motionTimes: [Double] = [first.t]
        var anchor = Point(x: first.x, y: first.y)
        for index in 1..<sorted.count {
            let dx = points[index].x - anchor.x
            let dy = points[index].y - anchor.y
            if dx * dx + dy * dy > epsilonSquared {
                motionTimes.append(times[index])
                anchor = points[index]
            }
        }

        // Opacity target is 1 for `idleSeconds` after each motion, then 0 until the next
        // motion. Encode that as breakpoints, then integrate the slew once to record the
        // exact opacity at every breakpoint — after which any query is O(1) and both public
        // entry points compute bit-identical values.
        var bpTimes: [Double] = []
        var bpTargets: [Double] = []
        for index in motionTimes.indices {
            let motion = motionTimes[index]
            let nextMotion = index + 1 < motionTimes.count ? motionTimes[index + 1] : .infinity
            bpTimes.append(motion)
            bpTargets.append(1.0)
            let idleTimeout = motion + config.idleSeconds
            if idleTimeout < nextMotion {
                bpTimes.append(idleTimeout)
                bpTargets.append(0.0)
            }
        }

        var integrated: [Double] = []
        integrated.reserveCapacity(bpTimes.count)
        var opacity = 1.0
        integrated.append(opacity)
        for index in 1..<bpTimes.count {
            // During [bpTimes[index-1], bpTimes[index]] the active target is bpTargets[index-1].
            opacity = Track.slew(
                from: opacity, toward: bpTargets[index - 1],
                over: bpTimes[index] - bpTimes[index - 1], fadeSeconds: config.fadeSeconds)
            integrated.append(opacity)
        }

        breakpointTimes = bpTimes
        breakpointTargets = bpTargets
        opacityAtBreakpoint = integrated
    }

    func frame(at t: Double, segmentHint: inout Int, breakpointHint: inout Int) -> CursorFrame? {
        guard let position = position(at: t, segmentHint: &segmentHint) else { return nil }
        let opacity = opacity(at: t, breakpointHint: &breakpointHint)
        return CursorFrame(position: position, opacity: opacity)
    }

    /// Catmull-Rom position at `t`. `nil` before the first sample; holds the last sample
    /// after the final one. `segmentHint` starts the bracket search and is advanced to the
    /// resolved segment (correct regardless of where the search began).
    private func position(at t: Double, segmentHint: inout Int) -> Point? {
        let count = times.count
        if t < times[0] { return nil }
        if t >= times[count - 1] { return points[count - 1] }

        var i = min(max(segmentHint, 0), count - 2)
        while i < count - 2, times[i + 1] <= t { i += 1 }
        while i > 0, times[i] > t { i -= 1 }
        segmentHint = i

        let p0 = points[max(0, i - 1)]
        let p1 = points[i]
        let p2 = points[i + 1]
        let p3 = points[min(count - 1, i + 2)]
        let t0 = times[max(0, i - 1)]
        let t1 = times[i]
        let t2 = times[i + 1]
        let t3 = times[min(count - 1, i + 2)]
        return Track.catmullRom(at: t, p0, p1, p2, p3, t0, t1, t2, t3)
    }

    /// Slew-limited opacity at `t`. `breakpointHint` starts (and is advanced to) the last
    /// breakpoint at or before `t`; the final value is `slew` from that breakpoint's exact
    /// opacity toward its active target.
    private func opacity(at t: Double, breakpointHint: inout Int) -> Double {
        var k = min(max(breakpointHint, 0), breakpointTimes.count - 1)
        while k < breakpointTimes.count - 1, breakpointTimes[k + 1] <= t { k += 1 }
        while k > 0, breakpointTimes[k] > t { k -= 1 }
        breakpointHint = k

        let value = Track.slew(
            from: opacityAtBreakpoint[k], toward: breakpointTargets[k],
            over: t - breakpointTimes[k], fadeSeconds: fadeSeconds)
        return min(1.0, max(0.0, value))
    }

    /// Move `value` toward `target` at 1/`fadeSeconds` per second over `dt` (`dt >= 0`),
    /// never past the target. A zero fade means instant snap.
    private static func slew(from value: Double, toward target: Double, over dt: Double, fadeSeconds: Double) -> Double {
        guard fadeSeconds > 0 else { return target }
        let maxDelta = dt / fadeSeconds
        if target > value { return min(target, value + maxDelta) }
        if target < value { return max(target, value - maxDelta) }
        return value
    }

    /// Non-uniform (time-parametrised) Catmull-Rom on the segment `[t1, t2]`, evaluated via
    /// cubic Hermite with tangents estimated over the surrounding time span. Reproduces a
    /// straight line exactly and returns the raw endpoint at a sample time (`t == t1`).
    private static func catmullRom(
        at t: Double,
        _ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point,
        _ t0: Double, _ t1: Double, _ t2: Double, _ t3: Double
    ) -> Point {
        let span = t2 - t1
        guard span > 0 else { return p1 }
        let s = (t - t1) / span

        // Time-derivative tangents (finite differences over the neighbouring interval).
        let m1x = derivative(p0.x, p2.x, over: t2 - t0)
        let m1y = derivative(p0.y, p2.y, over: t2 - t0)
        let m2x = derivative(p1.x, p3.x, over: t3 - t1)
        let m2y = derivative(p1.y, p3.y, over: t3 - t1)

        let s2 = s * s
        let s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1
        let h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2
        let h11 = s3 - s2

        let x = h00 * p1.x + h10 * span * m1x + h01 * p2.x + h11 * span * m2x
        let y = h00 * p1.y + h10 * span * m1y + h01 * p2.y + h11 * span * m2y
        return Point(x: x, y: y)
    }

    private static func derivative(_ from: Double, _ to: Double, over dt: Double) -> Double {
        guard dt > 0 else { return 0 }
        return (to - from) / dt
    }
}
