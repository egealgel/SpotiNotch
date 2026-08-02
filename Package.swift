// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DynamicNotch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DynamicNotch",
            path: "Sources/DynamicNotch"
        )
    ]
)
