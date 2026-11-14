// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppReviewWatcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AppReviewWatcher", path: "Sources/AppReviewWatcher")
    ]
)
