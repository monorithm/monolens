// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "monolens",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "monolens", targets: ["monolens"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "monolens",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // MediaProbe reads file attributes, a required-reason API. Also
                // declared in monolens.podspec -- CocoaPods and SPM each build
                // this plugin, and whichever one a consumer uses has to carry
                // the manifest or they hit ITMS-91053 at submission.
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
