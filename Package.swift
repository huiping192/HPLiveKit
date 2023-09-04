// swift-tools-version: 5.6
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
      .package(url: "https://github.com/huiping192/HPRTMP", .revision("ff8bdac4598413a17a02fa3105f7c9c335b9e34b")),
    ],
    targets: [
      .target(
        name: "HPLiveKit",
        dependencies: [
          .product(name: "HPRTMP", package: "HPRTMP")
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
