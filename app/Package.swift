// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UberTabber",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "UberTabber", path: "Sources/UberTabber")
    ]
)
