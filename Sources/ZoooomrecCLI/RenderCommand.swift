import Foundation
import RenderEngine
import ZoomTypes

enum RenderCommand {
    static func run(arguments: [String]) async throws {
        let (bundlePath, outputPath) = try parse(arguments)

        let bundleURL = URL(fileURLWithPath: bundlePath)
        let manifestURL = bundleURL.appendingPathComponent(ZoooomrecBundle.manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw CLIError.usage("not a .zoooomrec bundle (missing \(ZoooomrecBundle.manifestName)): \(bundlePath)")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        let printer = ProgressPrinter()
        let renderer = ZoomRenderer()
        try await renderer.render(projectBundle: bundleURL, outputURL: outputURL) { fraction in
            printer.report(fraction)
        }
        print("rendered: \(outputURL.path)")
    }

    /// Parses `<bundle path> --output <mp4 path>`; both are required.
    private static func parse(_ arguments: [String]) throws -> (bundle: String, output: String) {
        var bundlePath: String?
        var outputPath: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--output", "-o":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.usage("--output requires a path")
                }
                outputPath = arguments[index]
            default:
                guard bundlePath == nil else {
                    throw CLIError.usage("unexpected argument: \(argument)")
                }
                bundlePath = argument
            }
            index += 1
        }
        guard let bundlePath else {
            throw CLIError.usage("render requires a <path.zoooomrec> bundle path")
        }
        guard let outputPath else {
            throw CLIError.usage("render requires --output <out.mp4>")
        }
        return (bundlePath, outputPath)
    }
}

/// Prints render progress once per ~10% decile, thread-safely.
private final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDecile = -1

    func report(_ fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        let decile = min(10, max(0, Int(fraction * 10)))
        guard decile > lastDecile else { return }
        lastDecile = decile
        print("progress: \(decile * 10)%")
    }
}
