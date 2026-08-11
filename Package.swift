// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "whispr",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "whispr",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Whispr",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
