// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Flick",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Flick", targets: ["Flick"])
    ],
    targets: [
        .executableTarget(
            name: "Flick",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
