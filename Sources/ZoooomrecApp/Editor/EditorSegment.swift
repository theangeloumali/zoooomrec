import Foundation
import ZoomTypes

/// A zoom segment under edit.
///
/// The stable `id` keeps SwiftUI selection and `ForEach` identity intact across the
/// frequent re-sorts that dragging causes; `segment` is the value written back to
/// `project.json` on save.
struct EditableSegment: Identifiable, Equatable {
    let id: UUID
    var segment: ZoomSegment

    init(_ segment: ZoomSegment, id: UUID = UUID()) {
        self.id = id
        self.segment = segment
    }
}

/// Pure, side-effect-free timeline edits.
///
/// Every operation returns a list that is sorted by start, non-overlapping, and inside
/// `[0, duration]` — the invariants `ZoomTimeline` and the renderer assume. Keeping the
/// clamping here (not in the view) makes the rules obvious and keeps the model lean.
enum SegmentOps {
    /// Shortest a segment may become, so a block never collapses to an unclickable sliver
    /// and never falls below what the renderer treats as meaningful.
    static let minDuration = 0.3

    /// Default length of a freshly inserted zoom, before neighbour/clip clamping.
    static let defaultDuration = 2.0

    static func sorted(_ items: [EditableSegment]) -> [EditableSegment] {
        items.sorted { $0.segment.start < $1.segment.start }
    }

    /// The `[lower, upper]` time window an edit to `items[index]` must stay within:
    /// the previous segment's end (or clip start) and the next segment's start (or clip end).
    private static func window(around index: Int, in items: [EditableSegment], duration: Double) -> (lower: Double, upper: Double) {
        let lower = index > 0 ? items[index - 1].segment.end : 0
        let upper = index < items.count - 1 ? items[index + 1].segment.start : duration
        return (lower, upper)
    }

    /// Moves a segment in time by its start, preserving length and clamping so it never
    /// crosses a neighbour or leaves the clip.
    static func move(_ items: [EditableSegment], id: UUID, toStart newStart: Double, duration: Double) -> [EditableSegment] {
        var out = sorted(items)
        guard let index = out.firstIndex(where: { $0.id == id }) else { return out }
        var segment = out[index].segment
        let length = segment.end - segment.start
        let (lower, upper) = window(around: index, in: out, duration: duration)
        let clampedStart = min(max(lower, newStart), max(lower, upper - length))
        segment.start = clampedStart
        segment.end = clampedStart + length
        out[index].segment = segment
        return out
    }

    /// Drags the left edge, keeping the right edge fixed and honouring `minDuration`.
    static func resizeStart(_ items: [EditableSegment], id: UUID, to newStart: Double, duration: Double) -> [EditableSegment] {
        var out = sorted(items)
        guard let index = out.firstIndex(where: { $0.id == id }) else { return out }
        var segment = out[index].segment
        let (lower, _) = window(around: index, in: out, duration: duration)
        segment.start = min(max(lower, newStart), segment.end - minDuration)
        out[index].segment = segment
        return out
    }

    /// Drags the right edge, keeping the left edge fixed and honouring `minDuration`.
    static func resizeEnd(_ items: [EditableSegment], id: UUID, to newEnd: Double, duration: Double) -> [EditableSegment] {
        var out = sorted(items)
        guard let index = out.firstIndex(where: { $0.id == id }) else { return out }
        var segment = out[index].segment
        let (_, upper) = window(around: index, in: out, duration: duration)
        segment.end = max(min(upper, newEnd), segment.start + minDuration)
        out[index].segment = segment
        return out
    }

    /// Inserts a new zoom at `playhead`. If the playhead falls inside an existing segment
    /// the new one starts at that segment's end; the new segment fills the gap up to the
    /// next segment (capped at `defaultDuration`). Returns the updated list and the new
    /// segment's id, or `nil` when there is no room for a `minDuration` block.
    static func insert(
        _ items: [EditableSegment],
        atPlayhead playhead: Double,
        duration: Double,
        center: (x: Double, y: Double),
        scale: Double
    ) -> (items: [EditableSegment], id: UUID?) {
        let sortedItems = sorted(items)
        var start = min(max(0, playhead), duration)
        if let containing = sortedItems.first(where: { start >= $0.segment.start && start < $0.segment.end }) {
            start = containing.segment.end
        }
        let nextStart = sortedItems.first(where: { $0.segment.start >= start })?.segment.start ?? duration
        let end = min(start + defaultDuration, nextStart, duration)
        guard end - start >= minDuration else { return (sortedItems, nil) }

        let new = EditableSegment(
            ZoomSegment(start: start, end: end, centerX: center.x, centerY: center.y, scale: scale))
        return (sorted(sortedItems + [new]), new.id)
    }

    /// Projects the edited segments into the trimmed range for persistence: each segment is
    /// clamped to `[trimStart, trimEnd]` and dropped if it no longer spans `minDuration`.
    static func clampedToTrim(_ items: [EditableSegment], trimStart: Double, trimEnd: Double) -> [ZoomSegment] {
        sorted(items).compactMap { item in
            var segment = item.segment
            segment.start = max(segment.start, trimStart)
            segment.end = min(segment.end, trimEnd)
            return segment.end - segment.start >= minDuration ? segment : nil
        }
    }
}
