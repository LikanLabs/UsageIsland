// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageIslandPrototype",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "UsageIslandPrototype", targets: ["UsageIslandPrototype"])
    ],
    targets: [
        .executableTarget(
            name: "UsageIslandPrototype",
            path: "Sources/UsageIslandPrototype"
        ),
        .testTarget(
            name: "UsageIslandPrototypeTests",
            dependencies: ["UsageIslandPrototype"],
            path: "Tests/UsageIslandPrototypeTests"
        )
    ]
)
