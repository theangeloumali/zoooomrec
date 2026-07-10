import SwiftUI
import ZoomTypes

/// The zoomed preview: the frame at the playhead cropped to its zoom rect and scaled to fit.
///
/// When a segment is selected, a crosshair marks its focus point; dragging anywhere on the
/// canvas sets `centerX` / `centerY` in capture-space pixels by mapping the pointer through the
/// currently displayed crop rect.
struct PreviewCanvas: View {
    @ObservedObject var model: EditorModel

    private var aspect: CGFloat {
        model.height > 0 ? CGFloat(model.width / model.height) : 16.0 / 9.0
    }

    var body: some View {
        GeometryReader { geo in
            let display = fittedRect(aspect: aspect, in: geo.size)
            ZStack {
                Color.black
                if let image = model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }

                if let crosshair = crosshairPoint(in: display) {
                    Crosshair()
                        .position(crosshair)
                        .allowsHitTesting(false)
                }

                Text(String(format: "t = %.2fs", model.playhead))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white)
                    .padding(4)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .contentShape(Rectangle())
            .gesture(focusDrag(display: display))
        }
        .background(Color.black)
    }

    /// View-space location of the selected segment's focus point, or `nil` when nothing is
    /// selected or the focus falls outside the visible crop at this playhead.
    private func crosshairPoint(in display: CGRect) -> CGPoint? {
        guard let segment = model.selectedSegment?.segment,
              let crop = model.currentCrop,
              crop.width > 0, crop.height > 0 else { return nil }
        let fractionX = (segment.centerX - crop.minX) / crop.width
        let fractionY = (segment.centerY - crop.minY) / crop.height
        guard (0...1).contains(fractionX), (0...1).contains(fractionY) else { return nil }
        return CGPoint(
            x: display.minX + CGFloat(fractionX) * display.width,
            y: display.minY + CGFloat(fractionY) * display.height)
    }

    private func focusDrag(display: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.selectedID != nil,
                      let crop = model.currentCrop,
                      display.width > 0, display.height > 0 else { return }
                let fractionX = min(max(0, (value.location.x - display.minX) / display.width), 1)
                let fractionY = min(max(0, (value.location.y - display.minY) / display.height), 1)
                model.setSelectedCenter(
                    x: crop.minX + Double(fractionX) * crop.width,
                    y: crop.minY + Double(fractionY) * crop.height)
            }
    }
}

/// A focus-point marker: crosshair lines plus a ring, drawn with a shadow so it reads over any
/// frame content.
private struct Crosshair: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
                .frame(width: 22, height: 22)
            Rectangle().fill(Color.white).frame(width: 1, height: 30)
            Rectangle().fill(Color.white).frame(width: 30, height: 1)
        }
        .shadow(color: .black.opacity(0.7), radius: 1)
    }
}

/// The letterboxed rectangle an `aspect`-ratio image occupies when fit inside `size`.
/// Gestures map through this, matching how `.aspectRatio(.fit)` centres the image.
func fittedRect(aspect: CGFloat, in size: CGSize) -> CGRect {
    guard aspect > 0, size.width > 0, size.height > 0 else {
        return CGRect(origin: .zero, size: size)
    }
    var width = size.width
    var height = size.height
    if size.width / size.height > aspect {
        width = height * aspect
    } else {
        height = width / aspect
    }
    return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
}
