import Foundation
import XCTest

/// Guards the architecture invariant that `ZoomTypes` and `ZoomEngine` stay
/// platform-free (Foundation + ZoomTypes only). If either module ever imports a
/// platform framework, this test fails with the offending `file:line` — so the
/// "ports to iOS/Android/Windows unchanged" claim can never silently regress.
///
/// It reads the sources straight off disk via `#filePath`-relative navigation, so
/// it checks the real `Sources/` tree rather than a compiled artifact.
final class PlatformFreedomGuardTests: XCTestCase {
    /// Frameworks that must never appear in the platform-free core. `Foundation`
    /// (and `ZoomTypes`) are the only allowed imports.
    private static let forbidden = [
        "CoreGraphics", "AppKit", "UIKit", "AVFoundation",
        "CoreImage", "Cocoa", "ScreenCaptureKit",
    ]

    func testCoreModulesImportNoPlatformFrameworks() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ZoomEngineTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let sourceDirs = ["Sources/ZoomTypes", "Sources/ZoomEngine"]
            .map { repoRoot.appendingPathComponent($0) }

        let pattern = "^\\s*import\\s+(\(Self.forbidden.joined(separator: "|")))\\b"
        let regex = try NSRegularExpression(pattern: pattern)

        var violations: [String] = []
        var scanned = 0
        for dir in sourceDirs {
            let swiftFiles = Self.swiftFiles(in: dir)
            XCTAssertFalse(
                swiftFiles.isEmpty,
                "platform-freedom guard found no .swift files under \(dir.path) — the "
                    + "#filePath-relative source path is wrong; fix the guard rather than "
                    + "trusting a green run")
            for file in swiftFiles {
                let contents = try String(contentsOf: file, encoding: .utf8)
                let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() {
                    let text = String(line)
                    let range = NSRange(text.startIndex..., in: text)
                    if regex.firstMatch(in: text, range: range) != nil {
                        violations.append(
                            "\(file.path):\(index + 1): \(text.trimmingCharacters(in: .whitespaces))")
                    }
                }
                scanned += 1
            }
        }

        XCTAssertGreaterThan(scanned, 0, "platform-freedom guard scanned zero files")
        XCTAssertTrue(
            violations.isEmpty,
            """
            ZoomTypes/ZoomEngine must stay platform-free (Foundation + ZoomTypes only). \
            Forbidden import(s) found — move platform code to CaptureEngine/RenderEngine:
            \(violations.joined(separator: "\n"))
            """)
    }

    /// Recursively collects `.swift` files under `dir` (empty if `dir` is absent).
    private static func swiftFiles(in dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files
    }
}
