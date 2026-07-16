// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "FlickArrange",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FlickArrange", targets: ["FlickArrange"])
    ],
    targets: [
        .executableTarget(
            name: "FlickArrange",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
