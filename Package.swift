// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpotiNotch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SpotiNotch",
            path: "Sources/SpotiNotch"
        )
    ]
)
