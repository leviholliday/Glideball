// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Glide",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Glide",
            path: "Sources/Glide",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
