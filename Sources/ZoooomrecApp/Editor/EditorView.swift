import AppKit
import SwiftUI

/// Root layout for the editor window: preview on top, controls, timeline, then the
/// save/render bar. Falls back to a non-fatal error state when the bundle cannot be loaded.
struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        Group {
            if model.isLoaded {
                editor
            } else {
                ErrorState(message: model.errorMessage ?? "This recording could not be opened.")
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                banner(message)
            }
            PreviewCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controls
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            TimelineView(model: model)
                .padding(.horizontal, 14)
            Divider()
            saveBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.addZoomAtPlayhead()
            } label: {
                Label("Add Zoom", systemImage: "plus.magnifyingglass")
            }

            Button(role: .destructive) {
                model.deleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selectedID == nil)

            Divider().frame(height: 20)

            if let selected = model.selectedSegment {
                Text("Scale")
                Slider(value: scaleBinding(for: selected), in: 1...4, step: 0.1)
                    .frame(width: 160)
                Text(String(format: "%.1f×", selected.segment.scale))
                    .font(.body.monospacedDigit())
                    .frame(width: 40, alignment: .leading)
                Text("Drag the crosshair on the preview to set focus")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                Text("Select a zoom block to edit its scale and focus")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            Spacer()
        }
    }

    private func scaleBinding(for selected: EditableSegment) -> Binding<Double> {
        Binding(
            get: { model.selectedSegment?.segment.scale ?? selected.segment.scale },
            set: { model.setSelectedScale($0) })
    }

    // MARK: - Save / render bar

    private var saveBar: some View {
        HStack(spacing: 12) {
            Text("Trim \(timeLabel(model.trimStart))–\(timeLabel(model.trimEnd))  /  \(timeLabel(model.duration))")
                .font(.callout.monospacedDigit())
                .foregroundColor(.secondary)

            Spacer()

            if model.isRendering {
                ProgressView(value: model.renderProgress)
                    .frame(width: 180)
                Text("\(Int((model.renderProgress * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .leading)
            } else if let rendered = model.renderedURL {
                Text(rendered.lastPathComponent)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([rendered])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }

            Button {
                model.saveAndRender()
            } label: {
                Label("Save & Render", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.isRendering)
        }
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button {
                model.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private func timeLabel(_ seconds: Double) -> String {
        String(format: "%.2fs", seconds)
    }
}

/// Full-window error state for an unloadable / corrupt bundle — the window still opens so the
/// failure is visible, never a crash.
private struct ErrorState: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text("Cannot open this recording")
                .font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
