// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "video_recorder",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "video-recorder", targets: ["video_recorder"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "video_recorder",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
