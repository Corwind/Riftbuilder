// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RiftBuilder",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "RiftBuilderCore", targets: ["RiftBuilderCore"]),
        .executable(name: "RiftBuilder", targets: ["RiftBuilderApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
    ],
    targets: [
        .target(
            name: "RiftBuilderCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "RiftBuilderApp",
            dependencies: ["RiftBuilderCore"]
        ),
        .testTarget(
            name: "RiftBuilderCoreTests",
            dependencies: ["RiftBuilderCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
