// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QudelixBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QudelixBar",
            path: "Sources/QudelixBar"
        ),
        .testTarget(
            name: "QudelixBarTests",
            dependencies: ["QudelixBar"]
        )
    ]
)
