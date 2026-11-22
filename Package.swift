// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScreenshotUtility",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ScreenshotUtility", targets: ["ScreenshotUtility"])
    ],
    targets: [
        .executableTarget(name: "ScreenshotUtility"),
        .testTarget(name: "ScreenshotUtilityTests", dependencies: ["ScreenshotUtility"])
    ]
)
