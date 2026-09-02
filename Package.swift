// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ladder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LadderApp",
            path: "Sources/LadderApp",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
