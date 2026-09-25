// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "hotshot",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "HotshotCore",
            path: "Sources/HotshotCore"
        ),
        .executableTarget(
            name: "hotshot",
            dependencies: ["HotshotCore"],
            path: "Sources/hotshot"
        ),
        .testTarget(
            name: "HotshotCoreTests",
            dependencies: ["HotshotCore"],
            path: "Tests/HotshotCoreTests"
        ),
    ]
)
