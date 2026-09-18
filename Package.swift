// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Torrenza",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TorrentStorage", targets: ["TorrentStorage"]), .library(name: "TorrentEngine", targets: ["TorrentEngine"]), .library(name: "TorrentCore", targets: ["TorrentCore"]), .executable(name: "TorrentProbe", targets: ["TorrentProbe"])],
    targets: [
        .target(name: "TorrentCore"),
        .target(name: "TorrentWire", dependencies: ["TorrentCore"]),
        .target(name: "TorrentStorage", dependencies: ["TorrentCore"]),
        .target(name: "TorrentEngine", dependencies: ["TorrentCore", "TorrentWire", "TorrentStorage"]),
        .executableTarget(name: "TorrentProbe", dependencies: ["TorrentEngine", "TorrentCore"]),
        .testTarget(name: "TorrentCoreTests", dependencies: ["TorrentCore"]),
        .testTarget(name: "TorrentWireTests", dependencies: ["TorrentWire"]),
        .testTarget(name: "TorrentStorageTests", dependencies: ["TorrentStorage"]),
        .testTarget(name: "TorrentEngineTests", dependencies: ["TorrentEngine", "TorrentWire", "TorrentStorage"])
    ]
)
