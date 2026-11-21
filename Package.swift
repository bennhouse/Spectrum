// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Spectrum",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Spectrum", path: "Sources/Spectrum")
    ],
    swiftLanguageModes: [.v5]
)
