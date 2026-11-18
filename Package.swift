// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "island",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Island", dependencies: ["IslandCore"], path: "Sources/Island"),
        // The composer's state machine and the Grok roster watcher: Foundation only, so tests can drive them.
        .target(name: "IslandCore", path: "Sources/IslandCore"),
        .testTarget(
            name: "IslandCoreTests", dependencies: ["IslandCore"], path: "Tests/IslandCoreTests",
            resources: [.copy("Fixtures")]),
    ]
)
