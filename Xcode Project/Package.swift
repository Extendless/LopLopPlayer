// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MusicApp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MusicApp", targets: ["MusicApp"])],
    targets: [
        .executableTarget(name: "MusicApp", path: ".", exclude: ["sources", "Tests", "script", "dist", "Resources", "discord-cover-relay", "AGENTS.md", "README.md", "Package.swift"]),
        .testTarget(name: "MusicAppTests", dependencies: ["MusicApp"], path: "Tests/MusicAppTests")
    ]
)
