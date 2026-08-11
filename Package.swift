// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "whispr",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "whispr",
            path: "Sources/Whispr",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
