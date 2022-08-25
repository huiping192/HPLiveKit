// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HPLiveKit",
    platforms: [
            .iOS(.v8)
        ],
    dependencies: [
        .package(url: "https://github.com/huiping192/HPLibRTMP", from: "0.0.3"),
    ],
    targets: [
        .executableTarget(
            name: "HPLiveKit",
            dependencies: [
                "HPLibRTMP"
            ],
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("UIKit"),
            ]),
        .testTarget(
            name: "HPLiveKitTests",
            dependencies: ["HPLiveKit"]),
    ]
)
