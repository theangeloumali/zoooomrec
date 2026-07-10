import SwiftUI

/// The horizontal timeline: draggable/resizable zoom blocks, a scrub playhead, and two trim
/// handles, all laid out against the recording duration.
struct TimelineView: View {
    @ObservedObject var model: EditorModel

    private let trackHeight: CGFloat = 84
    private let verticalInset: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(model.duration, 0.0001)
            let midY = geo.size.height / 2

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .underPageBackgroundColor))
                    .frame(width: width, height: trackHeight)
                    .position(x: width / 2, y: midY)
                    .gesture(scrubGesture(width: width, duration: duration))

                trimmedOverlay(from: 0, to: model.trimStart, width: width, duration: duration, midY: midY)
                trimmedOverlay(from: model.trimEnd, to: duration, width: width, duration: duration, midY: midY)

                ForEach(model.segments) { item in
                    SegmentBlock(model: model, item: item, trackWidth: width, duration: duration, height: trackHeight - verticalInset)
                        .position(
                            x: blockCenterX(item, width: width, duration: duration),
                            y: midY)
                }

                trimHandle(time: model.trimStart, width: width, duration: duration, midY: midY) { model.setTrimStart($0) }
                trimHandle(time: model.trimEnd, width: width, duration: duration, midY: midY) { model.setTrimEnd($0) }

                playhead(width: width, duration: duration, height: trackHeight, midY: midY)
            }
            .coordinateSpace(name: Self.trackSpace)
        }
        .frame(height: trackHeight + 8)
    }

    /// Named coordinate space so every drag (scrub, playhead, trim handles) reads an absolute
    /// track-x regardless of which subview it started on — avoids per-gesture drag baselines.
    private static let trackSpace = "zoooomrec.timeline.track"

    // MARK: - Geometry helpers

    private func x(forTime time: Double, width: CGFloat, duration: Double) -> CGFloat {
        CGFloat(time / duration) * width
    }

    private func time(forX position: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, Double(position / width) * duration), duration)
    }

    private func blockCenterX(_ item: EditableSegment, width: CGFloat, duration: Double) -> CGFloat {
        let startX = x(forTime: item.segment.start, width: width, duration: duration)
        let blockWidth = max(x(forTime: item.segment.end - item.segment.start, width: width, duration: duration), SegmentBlock.minVisualWidth)
        return startX + blockWidth / 2
    }

    // MARK: - Sub-elements

    private func scrubGesture(width: CGFloat, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.trackSpace))
            .onChanged { value in
                model.scrub(to: time(forX: value.location.x, width: width, duration: duration))
            }
    }

    private func trimmedOverlay(from startTime: Double, to endTime: Double, width: CGFloat, duration: Double, midY: CGFloat) -> some View {
        let startX = x(forTime: startTime, width: width, duration: duration)
        let endX = x(forTime: endTime, width: width, duration: duration)
        let regionWidth = max(0, endX - startX)
        return RoundedRectangle(cornerRadius: 4)
            .fill(Color.black.opacity(0.45))
            .frame(width: regionWidth, height: trackHeight)
            .position(x: startX + regionWidth / 2, y: midY)
            .allowsHitTesting(false)
    }

    private func trimHandle(time: Double, width: CGFloat, duration: Double, midY: CGFloat, onDrag: @escaping (Double) -> Void) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).fill(Color.orange)
                .frame(width: 5, height: trackHeight)
            RoundedRectangle(cornerRadius: 2).fill(Color.orange)
                .frame(width: 12, height: 20)
        }
        .frame(width: 18, height: trackHeight)
        .contentShape(Rectangle())
        .position(x: x(forTime: time, width: width, duration: duration), y: midY)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.trackSpace))
                .onChanged { value in
                    onDrag(self.time(forX: value.location.x, width: width, duration: duration))
                })
        .help("Drag to trim")
    }

    private func playhead(width: CGFloat, duration: Double, height: CGFloat, midY: CGFloat) -> some View {
        let positionX = x(forTime: model.playhead, width: width, duration: duration)
        return ZStack {
            Rectangle().fill(Color.red).frame(width: 2, height: height)
            Circle().fill(Color.red).frame(width: 11, height: 11)
                .position(x: 7, y: 0)
        }
        .frame(width: 14, height: height)
        .contentShape(Rectangle())
        .position(x: positionX, y: midY)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.trackSpace))
                .onChanged { value in
                    model.scrub(to: time(forX: value.location.x, width: width, duration: duration))
                })
    }
}

/// One zoom segment on the track. The body drags to move; the two edge handles resize;
/// tapping selects. Drag baselines are captured in `@State` so each gesture translation is
/// applied to the value at drag-start, not accumulated.
struct SegmentBlock: View {
    static let minVisualWidth: CGFloat = 10

    @ObservedObject var model: EditorModel
    let item: EditableSegment
    let trackWidth: CGFloat
    let duration: Double
    let height: CGFloat

    @State private var moveBaseStart: Double?
    @State private var resizeBaseStart: Double?
    @State private var resizeBaseEnd: Double?

    private let edgeGrab: CGFloat = 9

    private var isSelected: Bool { model.selectedID == item.id }

    private var blockWidth: CGFloat {
        max(CGFloat((item.segment.end - item.segment.start) / max(duration, 0.0001)) * trackWidth, Self.minVisualWidth)
    }

    var body: some View {
        let blockWidth = self.blockWidth
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(isSelected ? 0.9 : 0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Color.white : Color.accentColor, lineWidth: isSelected ? 2 : 1))
                .onTapGesture { model.select(item.id) }
                .gesture(moveGesture)

            Text(String(format: "%.1f×", item.segment.scale))
                .font(.caption2.bold())
                .foregroundColor(.white)
                .allowsHitTesting(false)

            HStack {
                edgeHandle(isStart: true)
                Spacer(minLength: 0)
                edgeHandle(isStart: false)
            }
        }
        .frame(width: blockWidth, height: height)
    }

    private func edgeHandle(isStart: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(isSelected ? 0.9 : 0.4))
            .frame(width: edgeGrab, height: height)
            .contentShape(Rectangle())
            .gesture(resizeGesture(isStart: isStart))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let base = moveBaseStart ?? item.segment.start
                if moveBaseStart == nil { moveBaseStart = item.segment.start }
                model.select(item.id)
                model.move(id: item.id, toStart: base + delta(value.translation.width))
            }
            .onEnded { _ in moveBaseStart = nil }
    }

    /// One resize gesture for either edge — a single concrete `some Gesture` type so it can be
    /// chosen at runtime. The left edge moves `start`, the right edge moves `end`.
    private func resizeGesture(isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                model.select(item.id)
                let translation = delta(value.translation.width)
                if isStart {
                    let base = resizeBaseStart ?? item.segment.start
                    if resizeBaseStart == nil { resizeBaseStart = item.segment.start }
                    model.resizeStart(id: item.id, to: base + translation)
                } else {
                    let base = resizeBaseEnd ?? item.segment.end
                    if resizeBaseEnd == nil { resizeBaseEnd = item.segment.end }
                    model.resizeEnd(id: item.id, to: base + translation)
                }
            }
            .onEnded { _ in
                if isStart { resizeBaseStart = nil } else { resizeBaseEnd = nil }
            }
    }

    /// Converts a horizontal drag translation (points) into a time delta (seconds).
    private func delta(_ translation: CGFloat) -> Double {
        guard trackWidth > 0 else { return 0 }
        return Double(translation / trackWidth) * duration
    }
}
