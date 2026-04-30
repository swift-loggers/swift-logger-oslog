// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-logger-oslog",
    platforms: [
        .iOS(.v14),
        .tvOS(.v14),
        .macOS(.v11),
        .watchOS(.v7),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "LoggerOSLog",
            targets: ["LoggerOSLog"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swift-loggers/swift-logger.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "LoggerOSLog",
            dependencies: [
                .product(name: "Loggers", package: "swift-logger")
            ]
        ),
        .testTarget(
            name: "LoggerOSLogTests",
            dependencies: ["LoggerOSLog"]
        )
    ]
)
