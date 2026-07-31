// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StarFind",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StarFind",
            path: "Sources/StarFind",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
