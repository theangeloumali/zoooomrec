// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "zoooomrec",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "zoooomrec", targets: ["ZoooomrecCLI"]),
        .library(name: "ZoomEngine", targets: ["ZoomEngine"]),
    ],
    targets: [
        .target(name: "ZoomTypes"),
        .target(name: "ZoomEngine", dependencies: ["ZoomTypes"]),
        .target(name: "CaptureEngine", dependencies: ["ZoomTypes"]),
        .target(name: "RenderEngine", dependencies: ["ZoomTypes", "ZoomEngine"]),
        .executableTarget(
            name: "ZoooomrecCLI",
            dependencies: ["ZoomTypes", "ZoomEngine", "CaptureEngine", "RenderEngine"]
        ),
        .executableTarget(name: "E2EDemo", dependencies: ["ZoomTypes"]),
        .testTarget(name: "ZoomEngineTests", dependencies: ["ZoomEngine", "ZoomTypes"]),
        .testTarget(name: "RenderEngineTests", dependencies: ["RenderEngine", "ZoomEngine", "ZoomTypes"]),
    ]
)
