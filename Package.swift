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
        .target(
            name: "HotshotApp",
            dependencies: ["HotshotCore"],
            path: "Sources/HotshotApp"
        ),
        .executableTarget(
            name: "hotshot",
            dependencies: ["HotshotCore", "HotshotApp"],
            path: "Sources/hotshot"
        ),
        .testTarget(
            name: "HotshotCoreTests",
            dependencies: ["HotshotCore"],
            path: "Tests/HotshotCoreTests"
        ),
        .testTarget(
            name: "HotshotAppTests",
            dependencies: ["HotshotApp"],
            path: "Tests/HotshotAppTests"
        ),
    ]
)
