import Foundation
import ZoooomrecApp

enum CLIError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        }
    }
}

let usageText = """
zoooomrec — open-source zoomable screen recording

USAGE:
  zoooomrec app                                        menu-bar app (start/stop recording, zoom scale)
  zoooomrec record --output <path.zoooomrec> [options] record to a bundle, then auto-render an MP4
  zoooomrec render <path.zoooomrec> --output <out.mp4> render an existing bundle
  zoooomrec help
"""

@main
struct ZoooomrecCLI {
    /// True when this process was launched from inside `zoooomrec.app` (Finder, `open`,
    /// LaunchServices) rather than invoked as a terminal command.
    private static var launchedFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static func main() async {
        // LaunchServices historically appends a `-psn_0_12345` process-serial argument.
        let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }

        // Double-clicking the .app passes no arguments. Without this, the bundle would
        // print usage and exit(2) the instant the user launched it.
        guard let subcommand = args.first ?? (launchedFromAppBundle ? "app" : nil) else {
            print(usageText)
            exit(2)
        }
        do {
            switch subcommand {
            case "app":
                ZoooomrecApp.run()
            case "record":
                try await RecordCommand.run(arguments: Array(args.dropFirst()))
            case "render":
                try await RenderCommand.run(arguments: Array(args.dropFirst()))
            case "help", "--help", "-h":
                print(usageText)
            default:
                FileHandle.standardError.write(Data("unknown command: \(subcommand)\n\n\(usageText)\n".utf8))
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
