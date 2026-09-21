// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpeakerSync",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SpeakerSync",
            path: "Sources/SpeakerSync"
        )
    ]
)
