import XCTest
import ZoomTypes

@testable import ZoomEngine

final class CursorTrackTests: XCTestCase {
    private func move(_ t: Double, _ x: Double, _ y: Double) -> InputEvent {
        InputEvent(t: t, kind: .move, x: x, y: y)
    }

    // 26. No samples ⇒ nil; a `t` before the first sample ⇒ nil (the cursor has not appeared yet).
    func testEmptyAndBeforeFirstSampleReturnNil() {
        XCTAssertNil(CursorTrack.frame(at: 0.0, moves: []))

        let moves = [move(1.0, 100, 100), move(1.05, 120, 110)]
        XCTAssertNil(CursorTrack.frame(at: 0.5, moves: moves), "before the first sample the cursor does not exist")
        XCTAssertNotNil(CursorTrack.frame(at: 1.0, moves: moves), "at the first sample it appears")
    }

    // 27. At a sample's exact timestamp the spline returns that raw sample — no smoothing drift.
    func testPositionExactAtSampleTime() throws {
        let moves = [
            move(0.00, 100, 500),
            move(0.05, 220, 480),
            move(0.10, 300, 560),
            move(0.15, 410, 520),
        ]
        for sample in moves {
            let frame = try XCTUnwrap(CursorTrack.frame(at: sample.t, moves: moves))
            XCTAssertEqual(frame.position.x, sample.x, accuracy: 1e-9, "x must equal the raw sample at its time")
            XCTAssertEqual(frame.position.y, sample.y, accuracy: 1e-9, "y must equal the raw sample at its time")
        }
    }

    // 28. Smoothing property: on a straight line + alternating ±px jitter, the summed
    //     second-difference (jerk) of the Catmull-Rom path is materially lower than the raw
    //     stepped (no-smoothing) cursor sampled at the same frame times.
    func testSmoothingReducesJerk() {
        // 20 Hz jittery samples: linear x ramp, constant-y line + alternating ±8 px noise.
        var moves: [InputEvent] = []
        let sampleCount = 40
        for k in 0..<sampleCount {
            let t = Double(k) * 0.05 + Double((k * 7) % 5) * 0.003  // non-uniform intervals
            let x = 100.0 + 20.0 * Double(k)
            let y = 500.0 + (k % 2 == 0 ? 8.0 : -8.0)
            moves.append(move(t, x, y))
        }
        let duration = moves.last!.t
        let fps = 60.0
        let frameCount = Int((duration * fps).rounded(.up))

        var smoothed: [Point] = []
        var rawStepped: [Point] = []
        for j in 0..<frameCount {
            let t = Double(j) / fps
            guard let frame = CursorTrack.frame(at: t, moves: moves) else { continue }
            smoothed.append(frame.position)
            rawStepped.append(zeroOrderHold(at: t, moves: moves))
        }

        let smoothedJerk = summedSecondDifference(smoothed)
        let rawJerk = summedSecondDifference(rawStepped)
        print("jerk: smoothed=\(smoothedJerk) raw=\(rawJerk) ratio=\(smoothedJerk / rawJerk)")

        XCTAssertGreaterThan(rawJerk, 0, "the raw jittery path must actually be jerky")
        XCTAssertLessThan(
            smoothedJerk, 0.5 * rawJerk,
            "Catmull-Rom smoothing must materially reduce jerk vs the raw stepped cursor")
    }

    // 29. After the last sample the position holds at the final sample (no extrapolation).
    func testHoldsPositionAfterLastSample() throws {
        let moves = [move(0.0, 100, 100), move(0.1, 250, 300), move(0.2, 300, 300)]
        let frame = try XCTUnwrap(CursorTrack.frame(at: 5.0, moves: moves))
        XCTAssertEqual(frame.position.x, 300, accuracy: 1e-9)
        XCTAssertEqual(frame.position.y, 300, accuracy: 1e-9)
    }

    // 30. Hide-when-static: opacity is still 1 at exactly idleSeconds (fade has not begun),
    //     and 0 once idle for idleSeconds + fadeSeconds.
    func testHideWhenStatic() throws {
        // Pointer parks at one spot (within the idle epsilon) from t = 0.
        let moves = [move(0.0, 100, 100), move(0.5, 100, 100), move(1.0, 101, 100)]
        let config = CursorConfig()  // idle 2.0, fade 0.35

        let atIdle = try XCTUnwrap(CursorTrack.frame(at: config.idleSeconds, moves: moves, config: config))
        XCTAssertEqual(atIdle.opacity, 1.0, accuracy: 1e-9, "fade must not have started at exactly idleSeconds")

        let midFade = try XCTUnwrap(CursorTrack.frame(at: config.idleSeconds + config.fadeSeconds / 2, moves: moves, config: config))
        XCTAssertEqual(midFade.opacity, 0.5, accuracy: 1e-9, "halfway through the fade opacity is ~0.5")

        let hidden = try XCTUnwrap(CursorTrack.frame(at: config.idleSeconds + config.fadeSeconds, moves: moves, config: config))
        XCTAssertEqual(hidden.opacity, 0.0, accuracy: 1e-9, "fully hidden after idleSeconds + fadeSeconds")

        // And it stays hidden further out.
        let stillHidden = try XCTUnwrap(CursorTrack.frame(at: config.idleSeconds + config.fadeSeconds + 3.0, moves: moves, config: config))
        XCTAssertEqual(stillHidden.opacity, 0.0, accuracy: 1e-9)
    }

    // 31. Reappear: once fully hidden, resumed movement ramps opacity back up to 1 over fadeSeconds.
    func testReappearRampsBackToOne() throws {
        let config = CursorConfig()  // idle 2.0, fade 0.35
        let moves = [
            move(0.0, 100, 100),
            move(0.5, 100, 100),
            move(1.0, 100, 100),
            move(2.5, 100, 100),  // still parked ⇒ hidden by 2.35
            move(3.0, 400, 100),  // jumps 300 px ⇒ motion resumes at 3.0
            move(3.5, 400, 100),
        ]

        let beforeMotion = try XCTUnwrap(CursorTrack.frame(at: 2.6, moves: moves, config: config))
        XCTAssertEqual(beforeMotion.opacity, 0.0, accuracy: 1e-9, "hidden just before movement resumes")

        let mid = try XCTUnwrap(CursorTrack.frame(at: 3.0 + config.fadeSeconds / 2, moves: moves, config: config)).opacity
        XCTAssertGreaterThan(mid, 0.0, "opacity must climb, not stay hidden")
        XCTAssertLessThan(mid, 1.0, "and it climbs gradually, not instantly")
        XCTAssertEqual(mid, 0.5, accuracy: 1e-9, "halfway through the fade-in opacity is ~0.5")

        let reappeared = try XCTUnwrap(CursorTrack.frame(at: 3.0 + config.fadeSeconds, moves: moves, config: config))
        XCTAssertEqual(reappeared.opacity, 1.0, accuracy: 1e-9, "fully visible again after fadeSeconds of motion")
    }

    // 32. frames(...) agrees with frame(at:) at every sampled time, and its length is ceil(duration*fps).
    //     Includes a nil prefix (first sample at t = 0.1) to prove agreement on absent frames too.
    func testFramesMatchFrameAtAndLength() {
        let moves = [
            move(0.10, 100, 500),
            move(0.14, 220, 470),
            move(0.19, 260, 540),
            move(0.27, 360, 500),
            move(0.40, 500, 460),
        ]
        let fps = 60.0
        let duration = 0.6
        let frames = CursorTrack.frames(moves: moves, fps: fps, duration: duration)

        XCTAssertEqual(frames.count, Int((duration * fps).rounded(.up)))
        var sawNil = false
        var sawValue = false
        for j in 0..<frames.count {
            let t = Double(j) / fps
            let expected = CursorTrack.frame(at: t, moves: moves)
            XCTAssertEqual(frames[j], expected, "frames[\(j)] must equal frame(at: \(t))")
            if frames[j] == nil { sawNil = true } else { sawValue = true }
        }
        XCTAssertTrue(sawNil, "the nil prefix (before the first sample) must be exercised")
        XCTAssertTrue(sawValue, "the value tail must be exercised")
    }

    // 33. Empty moves ⇒ frames is all-nil with the correct length; degenerate fps/duration ⇒ empty.
    func testFramesEmptyAndDegenerate() {
        let empty = CursorTrack.frames(moves: [], fps: 30, duration: 1.0)
        XCTAssertEqual(empty.count, 30)
        XCTAssertTrue(empty.allSatisfy { $0 == nil })

        XCTAssertEqual(CursorTrack.frames(moves: [move(0, 1, 1)], fps: 0, duration: 1.0), [])
        XCTAssertEqual(CursorTrack.frames(moves: [move(0, 1, 1)], fps: 30, duration: 0), [])
    }

    // MARK: - Helpers

    /// The unsmoothed cursor: snap to the latest sample at or before `t` (zero-order hold).
    private func zeroOrderHold(at t: Double, moves: [InputEvent]) -> Point {
        var latest = Point(x: moves[0].x, y: moves[0].y)
        for event in moves where event.t <= t {
            latest = Point(x: event.x, y: event.y)
        }
        return latest
    }

    /// Sum of |p[i+1] - 2p[i] + p[i-1]| (2-D magnitude) — a discrete jerk proxy.
    private func summedSecondDifference(_ pts: [Point]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 1..<(pts.count - 1) {
            let ax = pts[i + 1].x - 2 * pts[i].x + pts[i - 1].x
            let ay = pts[i + 1].y - 2 * pts[i].y + pts[i - 1].y
            sum += (ax * ax + ay * ay).squareRoot()
        }
        return sum
    }
}
