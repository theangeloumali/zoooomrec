import XCTest
import ZoomTypes

@testable import ZoomEngine

final class AutoZoomTests: XCTestCase {
    private let width = 1920.0
    private let height = 1080.0

    private func click(_ t: Double, _ x: Double, _ y: Double, right: Bool = false) -> InputEvent {
        InputEvent(t: t, kind: right ? .rightClick : .leftClick, x: x, y: y)
    }

    private func move(_ t: Double, _ x: Double, _ y: Double) -> InputEvent {
        InputEvent(t: t, kind: .move, x: x, y: y)
    }

    private func scroll(_ t: Double, _ x: Double, _ y: Double) -> InputEvent {
        InputEvent(t: t, kind: .scroll, x: x, y: y)
    }

    private func key(_ t: Double, _ x: Double, _ y: Double) -> InputEvent {
        InputEvent(t: t, kind: .keyDown, x: x, y: y)
    }

    // 1. Empty event stream produces no segments.
    func testEmptyEventsProduceNoSegments() {
        XCTAssertEqual(AutoZoom.segments(from: [], width: width, height: height), [])
    }

    // 2. Moves and scrolls alone never create segments.
    func testMovesAndScrollsOnlyProduceNoSegments() {
        let events = [
            move(0.1, 500, 500),
            scroll(0.5, 500, 500),
            move(1.0, 900, 300),
            scroll(2.0, 100, 100),
        ]
        XCTAssertEqual(AutoZoom.segments(from: events, width: width, height: height), [])
    }

    // 3. A single click yields one segment with exact bounds, center, and scale.
    func testSingleClickExactBounds() {
        let events = [click(5.0, 800, 400)]
        let segs = AutoZoom.segments(from: events, width: width, height: height)
        XCTAssertEqual(segs.count, 1)
        let s = segs[0]
        XCTAssertEqual(s.start, 4.2, accuracy: 1e-9)  // 5.0 - leadIn(0.8)
        XCTAssertEqual(s.end, 6.6, accuracy: 1e-9)  // 5.0 + holdPad(0.6) + leadOut(1.0)
        XCTAssertEqual(s.centerX, 800, accuracy: 1e-9)
        XCTAssertEqual(s.centerY, 400, accuracy: 1e-9)
        XCTAssertEqual(s.scale, 2.0, accuracy: 1e-9)  // zoomScale default
    }

    // 4. leadIn is clamped to >= 0 when the click sits near t = 0.
    func testLeadInClampedAtStart() {
        let events = [click(0.3, 640, 360)]
        let segs = AutoZoom.segments(from: events, width: width, height: height)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 0.0, accuracy: 1e-9)  // max(0, 0.3 - 0.8)
        XCTAssertEqual(segs[0].end, 1.9, accuracy: 1e-9)  // 0.3 + 1.6
    }

    // 5. Rapid nearby clicks collapse into ONE cluster with the mean centroid.
    func testRapidNearbyClicksClusterIntoOne() {
        let events = [
            click(1.0, 500, 500),
            click(1.4, 510, 500),
            click(1.8, 490, 500),
        ]
        let segs = AutoZoom.segments(from: events, width: width, height: height)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 0.2, accuracy: 1e-9)  // 1.0 - 0.8
        XCTAssertEqual(segs[0].end, 3.4, accuracy: 1e-9)  // 1.8 + 1.6
        XCTAssertEqual(segs[0].centerX, 500, accuracy: 1e-9)  // mean(500,510,490)
        XCTAssertEqual(segs[0].centerY, 500, accuracy: 1e-9)
    }

    // 6. Clicks distant in time (and space) stay separate, non-overlapping.
    func testDistantClicksProduceSeparateSegments() {
        let events = [
            click(1.0, 300, 300),
            click(6.0, 1500, 300),
        ]
        let segs = AutoZoom.segments(from: events, width: width, height: height)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(segs[0].end, 2.6, accuracy: 1e-9)
        XCTAssertEqual(segs[1].start, 5.2, accuracy: 1e-9)
        XCTAssertEqual(segs[1].end, 7.6, accuracy: 1e-9)
        // Sorted and non-overlapping.
        XCTAssertLessThan(segs[0].end, segs[1].start)
    }

    // 7. Spatially-distant but temporally-close clicks split into two clusters
    //    that then MERGE (anti-pumping) with a click-count-weighted centroid.
    func testAdjacentSegmentsMergeWithWeightedCentroid() {
        let events = [
            click(1.0, 200, 500),
            click(1.3, 200, 500),
            click(1.6, 200, 500),  // cluster A: 3 clicks at x=200
            click(2.0, 1600, 500),  // cluster B: 1 click at x=1600 (distance > 0.25*width)
        ]
        let segs = AutoZoom.segments(from: events, width: width, height: height)
        XCTAssertEqual(segs.count, 1, "adjacent segments must merge — no zoom pumping")
        // Weighted by click count: (200*3 + 1600*1) / 4 = 550, NOT the midpoint 900.
        XCTAssertEqual(segs[0].centerX, 550, accuracy: 1e-9)
        XCTAssertEqual(segs[0].centerY, 500, accuracy: 1e-9)
        XCTAssertEqual(segs[0].start, 0.2, accuracy: 1e-9)  // min start
        XCTAssertEqual(segs[0].end, 3.6, accuracy: 1e-9)  // max end (2.0 + 1.6)
    }

    // 8. Segments shorter than minDuration are dropped (custom config).
    func testShortSegmentsDropped() {
        let config = AutoZoomConfig(minDuration: 5.0)
        // A lone click spans 2.4s < 5.0 -> dropped.
        let short = AutoZoom.segments(from: [click(5.0, 800, 400)], width: width, height: height, config: config)
        XCTAssertEqual(short, [])
        // A cluster spanning 4s survives (duration 6.4 >= 5.0).
        let long = AutoZoom.segments(
            from: [click(5.0, 800, 400), click(7.0, 800, 400), click(9.0, 800, 400)],
            width: width, height: height, config: config)
        XCTAssertEqual(long.count, 1)
        XCTAssertGreaterThanOrEqual(long[0].end - long[0].start, 5.0)
    }

    // 9. key_down events extend the cluster end but do NOT shift its centroid.
    func testKeyDownExtendsEndButNotCentroid() {
        let events = [
            click(1.0, 100, 100),
            key(2.0, 999, 999),
            key(3.0, 999, 999),
            key(3.9, 999, 999),
        ]
        let segs = AutoZoom.segments(from: events, width: width, height: height)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].end, 5.5, accuracy: 1e-9)  // 3.9 + 1.6, extended by typing hold
        XCTAssertEqual(segs[0].centerX, 100, accuracy: 1e-9)  // unaffected by key_down x
        XCTAssertEqual(segs[0].centerY, 100, accuracy: 1e-9)
    }

    // 10. Right-clicks cluster identically to left-clicks; unsorted input is handled.
    func testRightClicksAndUnsortedInput() {
        let events = [
            click(1.8, 600, 600, right: true),
            click(1.0, 600, 600),
            click(1.4, 600, 600, right: true),
        ]
        let segs = AutoZoom.segments(from: events, width: width, height: height)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(segs[0].end, 3.4, accuracy: 1e-9)
    }
}

final class ZoomTimelineTests: XCTestCase {
    private let width = 1920.0
    private let height = 1080.0

    private func assertInBounds(_ rect: Rect, _ w: Double, _ h: Double, line: UInt = #line) {
        let eps = 1e-6
        XCTAssertGreaterThanOrEqual(rect.minX, -eps, "rect.minX escaped left", line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, -eps, "rect.minY escaped top", line: line)
        XCTAssertLessThanOrEqual(rect.maxX, w + eps, "rect.maxX escaped right", line: line)
        XCTAssertLessThanOrEqual(rect.maxY, h + eps, "rect.maxY escaped bottom", line: line)
        XCTAssertGreaterThan(rect.width, 0, "rect width must be positive", line: line)
        XCTAssertGreaterThan(rect.height, 0, "rect height must be positive", line: line)
    }

    // 11. Keyframe count matches ceil(duration*fps) and timestamps are monotonic.
    func testKeyframeCountAndMonotonicTimestamps() {
        let fps = 30.0
        let duration = 3.0
        let frames = ZoomTimeline.cropKeyframes(
            segments: [], width: width, height: height, fps: fps, duration: duration)
        XCTAssertEqual(frames.count, Int((duration * fps).rounded(.up)))
        for i in 1..<frames.count {
            XCTAssertGreaterThan(frames[i].t, frames[i - 1].t)
            XCTAssertEqual(frames[i].t, Double(i) / fps, accuracy: 1e-9)
        }
    }

    // 12. With no segments every frame is the full frame.
    func testNoSegmentsYieldFullFrame() {
        let frames = ZoomTimeline.cropKeyframes(
            segments: [], width: width, height: height, fps: 30, duration: 1.0)
        for f in frames {
            XCTAssertEqual(f.rect, Rect(x: 0, y: 0, width: width, height: height))
        }
    }

    // 13. The spring converges to the target scale (<=1% error), no overshoot.
    //     At the new omega (4.2, ≈1s glide) convergence to 1% takes ≈2s, so the
    //     tolerance is checked at t≈2s rather than the old omega-8 1s window.
    func testSpringConvergesWithoutOvershoot() {
        let fps = 60.0
        let target = 2.0
        let seg = ZoomSegment(start: 0.0, end: 5.0, centerX: width / 2, centerY: height / 2, scale: target)
        let frames = ZoomTimeline.cropKeyframes(
            segments: [seg], width: width, height: height, fps: fps, duration: 2.0)
        for f in frames {
            let scale = width / f.rect.width
            XCTAssertLessThanOrEqual(scale, target + 1e-9, "critically damped spring must not overshoot")
            XCTAssertGreaterThanOrEqual(scale, 1.0 - 1e-9, "scale must never drop below 1.0")
        }
        // By t ≈ 2s the scale must be within 1% of the target.
        let atTwoSeconds = frames[frames.count - 1]
        let scale = width / atTwoSeconds.rect.width
        XCTAssertEqual(scale, target, accuracy: 0.01 * target)
    }

    // 14. Corner-click at high zoom: every crop rect stays fully in bounds mid-flight.
    func testCornerClickStaysInBoundsThroughAnimation() {
        let w = 1000.0
        let h = 1000.0
        let maxScale = 4.0
        let seg = ZoomSegment(start: 0.0, end: 3.0, centerX: 0, centerY: 0, scale: maxScale)
        let frames = ZoomTimeline.cropKeyframes(
            segments: [seg], width: w, height: h, fps: 30, duration: 3.0)
        XCTAssertFalse(frames.isEmpty)
        for f in frames {
            assertInBounds(f.rect, w, h)
            let scale = w / f.rect.width
            XCTAssertLessThanOrEqual(scale, maxScale + 1e-9)
            XCTAssertGreaterThanOrEqual(scale, 1.0 - 1e-9)
        }
    }

    // 15. After a segment ends the view settles back to (nearly) the full frame.
    //     Release eases out with the slower releaseOmega (3.2), so the settle window
    //     is ≈3s — duration extended to give the slower relax room to reach 1%.
    func testSettlesBackToFullFrameOutsideSegment() {
        let w = 1000.0
        let h = 1000.0
        let seg = ZoomSegment(start: 0.0, end: 2.0, centerX: 300, centerY: 300, scale: 2.0)
        let frames = ZoomTimeline.cropKeyframes(
            segments: [seg], width: w, height: h, fps: 30, duration: 5.0)
        let last = frames[frames.count - 1]  // ~2.97s after the segment ended
        let scale = w / last.rect.width
        XCTAssertEqual(scale, 1.0, accuracy: 0.01)
        XCTAssertEqual(last.rect.minX, 0.0, accuracy: w * 0.01)
        XCTAssertEqual(last.rect.minY, 0.0, accuracy: h * 0.01)
        XCTAssertEqual(last.rect.width, w, accuracy: w * 0.01)
        XCTAssertEqual(last.rect.height, h, accuracy: h * 0.01)
    }

    // 16. Zero duration yields no frames; every rect from a full run stays in bounds.
    func testZeroDurationAndGlobalBoundsInvariant() {
        XCTAssertEqual(
            ZoomTimeline.cropKeyframes(segments: [], width: width, height: height, fps: 30, duration: 0),
            [])

        let segs = [
            ZoomSegment(start: 0.5, end: 2.0, centerX: 50, centerY: 50, scale: 3.0),
            ZoomSegment(start: 3.0, end: 4.5, centerX: width - 50, centerY: height - 50, scale: 2.5),
        ]
        let frames = ZoomTimeline.cropKeyframes(
            segments: segs, width: width, height: height, fps: 30, duration: 5.0)
        for f in frames { assertInBounds(f.rect, width, height) }
    }
}

final class ManualZoomTests: XCTestCase {
    private let width = 1920.0
    private let height = 1080.0
    private let scale = 2.0

    private func zoomIn(_ t: Double, _ x: Double, _ y: Double) -> InputEvent {
        InputEvent(t: t, kind: .zoomIn, x: x, y: y)
    }

    private func zoomOut(_ t: Double) -> InputEvent {
        InputEvent(t: t, kind: .zoomOut, x: 0, y: 0)
    }

    // 17. A single in→out pair yields one segment with exact bounds/center/scale.
    func testSingleInOutPairExactBounds() {
        let events = [zoomIn(1.0, 800, 400), zoomOut(3.0)]
        let segs = ManualZoom.segments(
            from: events, width: width, height: height, scale: scale, duration: 10.0)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(segs[0].end, 3.0, accuracy: 1e-9)
        XCTAssertEqual(segs[0].centerX, 800, accuracy: 1e-9)  // in [480, 1440] — unclamped
        XCTAssertEqual(segs[0].centerY, 400, accuracy: 1e-9)  // in [270, 810] — unclamped
        XCTAssertEqual(segs[0].scale, scale, accuracy: 1e-9)
    }

    // 18. An unclosed zoom runs to the clip duration.
    func testUnclosedZoomRunsToDuration() {
        let events = [zoomIn(2.0, 500, 500)]
        let segs = ManualZoom.segments(
            from: events, width: width, height: height, scale: scale, duration: 8.0)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 2.0, accuracy: 1e-9)
        XCTAssertEqual(segs[0].end, 8.0, accuracy: 1e-9)  // to duration
    }

    // 19. zoomIn while open = retarget → two contiguous segments, different centers.
    func testRetargetProducesTwoContiguousSegments() {
        let events = [zoomIn(1.0, 600, 300), zoomIn(4.0, 1400, 300)]
        let segs = ManualZoom.segments(
            from: events, width: width, height: height, scale: scale, duration: 10.0)
        XCTAssertEqual(segs.count, 2)
        // First closes exactly where the second opens — contiguous, no gap.
        XCTAssertEqual(segs[0].end, segs[1].start, accuracy: 1e-9)
        XCTAssertEqual(segs[0].start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(segs[0].end, 4.0, accuracy: 1e-9)
        XCTAssertEqual(segs[1].end, 10.0, accuracy: 1e-9)  // unclosed → to duration
        XCTAssertEqual(segs[0].centerX, 600, accuracy: 1e-9)   // in [480, 1440] — unclamped
        XCTAssertEqual(segs[1].centerX, 1400, accuracy: 1e-9)  // in [480, 1440] — unclamped
        XCTAssertNotEqual(segs[0].centerX, segs[1].centerX)
    }

    // 20. A stray zoomOut (nothing open) is ignored; extras never corrupt a real pair.
    func testStrayZoomOutIgnored() {
        let events = [zoomOut(1.0), zoomIn(2.0, 400, 400), zoomOut(3.0), zoomOut(5.0)]
        let segs = ManualZoom.segments(
            from: events, width: width, height: height, scale: scale, duration: 10.0)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 2.0, accuracy: 1e-9)
        XCTAssertEqual(segs[0].end, 3.0, accuracy: 1e-9)
    }

    // 21. No markers → no segments.
    func testEmptyProducesNoSegments() {
        XCTAssertEqual(
            ManualZoom.segments(from: [], width: width, height: height, scale: scale, duration: 10.0),
            [])
        // Non-marker events alone also produce nothing.
        let noise = [
            InputEvent(t: 1.0, kind: .move, x: 100, y: 100),
            InputEvent(t: 2.0, kind: .leftClick, x: 200, y: 200),
        ]
        XCTAssertEqual(
            ManualZoom.segments(from: noise, width: width, height: height, scale: scale, duration: 10.0),
            [])
    }
}

final class ZoomTimelineFollowTests: XCTestCase {
    private let width = 1920.0
    private let height = 1080.0

    private func move(_ t: Double, _ x: Double, _ y: Double) -> InputEvent {
        InputEvent(t: t, kind: .move, x: x, y: y)
    }

    private func cropCenterX(_ frame: CropKeyframe) -> Double { frame.rect.midX }

    private func assertInBounds(_ rect: Rect, _ w: Double, _ h: Double, line: UInt = #line) {
        let eps = 1e-6
        XCTAssertGreaterThanOrEqual(rect.minX, -eps, "rect.minX escaped left", line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, -eps, "rect.minY escaped top", line: line)
        XCTAssertLessThanOrEqual(rect.maxX, w + eps, "rect.maxX escaped right", line: line)
        XCTAssertLessThanOrEqual(rect.maxY, h + eps, "rect.maxY escaped bottom", line: line)
        XCTAssertGreaterThan(rect.width, 0, "rect width must be positive", line: line)
        XCTAssertGreaterThan(rect.height, 0, "rect height must be positive", line: line)
    }

    // 22. Inside a segment the target tracks the cursor with a dead-zone: a sub-threshold
    //     move causes no drift (no jitter), a large move pans the crop toward the cursor.
    func testCursorFollowDeadZoneAndRetarget() {
        let fps = 60.0
        let cx = width / 2   // 960
        let cy = height / 2  // 540
        let seg = ZoomSegment(start: 0.0, end: 10.0, centerX: cx, centerY: cy, scale: 2.0)
        let events = [
            move(0.0, cx, cy),        // cursor starts at the zoom center
            move(5.0, 1000, 540),     // small move (Δ40) — inside the dead-zone
            move(8.0, 1500, 540),     // large move (Δ540) — leaves the dead-zone
        ]
        let frames = ZoomTimeline.cropKeyframes(
            segments: [seg], events: events, width: width, height: height, fps: fps, duration: 10.0)

        // Before the large move, the sub-threshold move did NOT drag the crop center.
        let atSeven = frames[Int(7.0 * fps)]
        XCTAssertEqual(cropCenterX(atSeven), cx, accuracy: 5.0, "sub-threshold move must not jitter the crop")

        // After the large move, the crop pans toward the cursor (clamped to 1440 at scale 2).
        let last = frames[frames.count - 1]
        XCTAssertGreaterThan(cropCenterX(last), 1200.0, "crop must follow the cursor after a large move")
        XCTAssertLessThanOrEqual(cropCenterX(last), 1440.0 + 1e-6, "clamped so the crop stays in frame")
        for f in frames { assertInBounds(f.rect, width, height) }
    }

    // 23. Release (zoom-out) reaches near-1.0 SLOWER than the attack reaches near-target.
    func testReleaseEasesOutSlowerThanAttack() {
        let fps = 60.0
        let target = 2.0
        // Attack over [0, 3], release from 3s onward.
        let seg = ZoomSegment(start: 0.0, end: 3.0, centerX: width / 2, centerY: height / 2, scale: target)
        let frames = ZoomTimeline.cropKeyframes(
            segments: [seg], width: width, height: height, fps: fps, duration: 7.0)
        let scales = frames.map { (t: $0.t, scale: width / $0.rect.width) }

        // First frame where the attack is 90% of the way to the target (scale >= 1.9).
        guard let attack = scales.first(where: { $0.scale >= 1.9 }) else {
            return XCTFail("attack never reached near-target")
        }
        // First frame after the segment ends where release is 90% back to 1.0 (scale <= 1.1).
        guard let release = scales.first(where: { $0.t > 3.0 && $0.scale <= 1.1 }) else {
            return XCTFail("release never reached near-1.0")
        }
        let attackElapsed = attack.t          // from t = 0
        let releaseElapsed = release.t - 3.0  // from segment end
        XCTAssertGreaterThan(
            releaseElapsed, attackElapsed,
            "releaseOmega (3.2) must ease out slower than omega (4.2) eases in")
    }

    // 24. Cursor-follow overload stays in-bounds and never overshoots through a corner
    //     zoom at the new omega (4.2). No move events → target is the segment center.
    func testFollowCornerZoomInBoundsNoOvershoot() {
        let w = 1000.0
        let h = 1000.0
        let maxScale = 4.0
        let seg = ZoomSegment(start: 0.0, end: 3.0, centerX: 0, centerY: 0, scale: maxScale)
        let frames = ZoomTimeline.cropKeyframes(
            segments: [seg], events: [], width: w, height: h, fps: 30, duration: 3.0)
        XCTAssertFalse(frames.isEmpty)
        for f in frames {
            assertInBounds(f.rect, w, h)
            let scale = w / f.rect.width
            XCTAssertLessThanOrEqual(scale, maxScale + 1e-9, "must not overshoot the target scale")
            XCTAssertGreaterThanOrEqual(scale, 1.0 - 1e-9, "scale must never drop below 1.0")
        }
    }
}
