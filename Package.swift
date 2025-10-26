// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HPLiveKit",
    platforms: [.iOS(.v14)],
    products: [
      .library(
        name: "HPLiveKit",
        targets: ["HPLiveKit"]),
    ], dependencies: [
      .package(url: "https://github.com/huiping192/HPRTMP.git", revision: "85e51c444d850f074b64a63dbfa75d69ebd21c21"),
      .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0")
    ],
    targets: [
      .target(
        name: "HPLiveKit",
        dependencies: [
          .product(name: "HPRTMP", package: "HPRTMP"),
          .product(name: "NIOCore", package: "swift-nio"),
          .product(name: "NIOFoundationCompat", package: "swift-nio")
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
