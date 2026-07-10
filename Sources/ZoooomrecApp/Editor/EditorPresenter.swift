import AppKit
import Foundation
import SwiftUI

/// Opens the zoom-timeline editor for a `.zoooomrec` bundle.
///
/// Editing needs no permissions: the editor writes explicit `segments` into `project.json`
/// (which already take precedence over both zoom lanes) and re-renders.
///
/// Owned by the Editor packet.
enum EditorPresenter {
    /// Retained window controllers keyed by bundle path, so an open editor is never
    /// deallocated out from under its window and presenting the same bundle twice focuses the
    /// existing window instead of opening a second one. Touched only on the main thread.
    private static var controllers: [String: EditorWindowController] = [:]

    /// Presents the editor window for `bundleURL`.
    /// - Parameter onRendered: called on the main thread with the freshly rendered MP4
    ///   whenever the user saves and re-renders, so the menu bar can update its state.
    static func present(bundleURL: URL, onRendered: ((URL) -> Void)? = nil) {
        assert(Thread.isMainThread, "EditorPresenter.present must be called on the main thread")
        let key = bundleURL.standardizedFileURL.path

        if let existing = controllers[key] {
            existing.focus()
            return
        }

        let controller = EditorWindowController(bundleURL: bundleURL, onRendered: onRendered) {
            controllers[key] = nil
        }
        controllers[key] = controller
        controller.focus()
    }
}

/// Hosts the SwiftUI editor in an `NSWindow`. As an `.accessory` app, the window will not come
/// forward unless we explicitly activate — hence `focus()` both orders front and activates.
private final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(bundleURL: URL, onRendered: ((URL) -> Void)?, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let model = EditorModel(bundleURL: bundleURL, onRendered: onRendered)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "zoooomrec — \(bundleURL.lastPathComponent)"
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = NSHostingView(rootView: EditorView(model: model))
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Orders the window front and pulls a menu-bar-only app forward.
    func focus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
