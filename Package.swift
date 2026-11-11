// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpotifySampler",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(name: "SpotifySampler", path: "Sources/SpotifySampler")
    ]
)
