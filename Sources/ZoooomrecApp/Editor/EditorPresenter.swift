import Foundation

/// Opens the zoom-timeline editor for a `.zoooomrec` bundle.
///
/// Editing needs no permissions: the editor writes explicit `segments` into `project.json`
/// (which already take precedence over both zoom lanes) and re-renders.
///
/// Owned by the Editor packet — replace this stub, keep the API.
enum EditorPresenter {
    /// Presents the editor window for `bundleURL`.
    /// - Parameter onRendered: called on the main thread with the freshly rendered MP4
    ///   whenever the user saves and re-renders, so the menu bar can update its state.
    static func present(bundleURL: URL, onRendered: ((URL) -> Void)? = nil) {
        NSLog("zoooomrec: editor not implemented yet (scaffold stub): \(bundleURL.path)")
    }
}
