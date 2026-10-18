// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Uno",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Uno",
            path: "Sources/Uno"
        ),
        .testTarget(
            name: "UnoTests",
            dependencies: ["Uno"],
            path: "Tests/UnoTests"
        )
    ]
)
