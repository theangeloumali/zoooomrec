import CoreGraphics
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

    private func assertInBounds(_ rect: CGRect, _ w: Double, _ h: Double, line: UInt = #line) {
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
            XCTAssertEqual(f.rect, CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // 13. The spring converges to the target scale within 1s (<=1% error), no overshoot.
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
        // At t = 1s the scale must be within 1% of the target.
        let atOneSecond = frames[Int(fps) - 1]
        let scale = width / atOneSecond.rect.width
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
    func testSettlesBackToFullFrameOutsideSegment() {
        let w = 1000.0
        let h = 1000.0
        let seg = ZoomSegment(start: 0.0, end: 2.0, centerX: 300, centerY: 300, scale: 2.0)
        let frames = ZoomTimeline.cropKeyframes(
            segments: [seg], width: w, height: h, fps: 30, duration: 4.0)
        let last = frames[frames.count - 1]  // ~1.97s after the segment ended
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
