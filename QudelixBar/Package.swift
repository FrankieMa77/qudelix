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
        .executableTarget(
            name: "qxprobe",
            path: "Sources/qxprobe"
        ),
        .executableTarget(
            name: "qxusb",
            path: "Sources/qxusb"
        ),
        .testTarget(
            name: "QudelixBarTests",
            dependencies: ["QudelixBar"]
        )
    ]
)
