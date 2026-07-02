// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Videopaper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Videopaper", targets: ["Videopaper"])
    ],
    targets: [
        .executableTarget(
            name: "Videopaper",
            path: "Sources/Videopaper"
        )
    ]
)
