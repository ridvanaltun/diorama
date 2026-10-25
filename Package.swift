// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Diorama",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "dioramad", targets: ["dioramad"]),
        .executable(name: "diorama", targets: ["diorama"]),
        .executable(name: "DioramaApp", targets: ["DioramaApp"]),
        .library(name: "DioramaClient", targets: ["DioramaClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "DioramaCore"),
        .target(name: "DioramaJSON"),
        .target(
            name: "DioramaStore",
            dependencies: ["DioramaCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "DioramaEngine", dependencies: ["DioramaCore", "DioramaJSON", "DioramaStore"]),
        .target(
            name: "DioramaGateway",
            dependencies: [
                "DioramaCore", "DioramaJSON", "DioramaStore", "DioramaEngine", "DioramaRunner",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .target(name: "DioramaRunner", dependencies: ["DioramaCore", "DioramaStore", "DioramaEngine"]),
        .target(name: "DioramaClient", dependencies: ["DioramaCore"]),
        .executableTarget(name: "dioramad", dependencies: ["DioramaGateway", "DioramaCore"]),
        .executableTarget(
            name: "diorama",
            dependencies: [
                "DioramaClient", "DioramaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "DioramaApp", dependencies: ["DioramaClient", "DioramaCore"]),
        .target(
            name: "DioramaTestSupport",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/DioramaTestSupport"
        ),
        .testTarget(name: "DioramaJSONTests", dependencies: ["DioramaJSON"]),
        .testTarget(name: "DioramaEngineTests", dependencies: ["DioramaEngine", "DioramaStore", "DioramaJSON", "DioramaCore"]),
        .testTarget(
            name: "DioramaGatewayTests",
            dependencies: [
                "DioramaGateway", "DioramaClient", "DioramaEngine", "DioramaStore", "DioramaCore", "DioramaTestSupport",
            ]
        ),
        .testTarget(name: "DioramaRunnerTests", dependencies: ["DioramaRunner", "DioramaEngine", "DioramaStore", "DioramaCore"]),
        .testTarget(
            name: "DioramaContractTests",
            dependencies: ["DioramaGateway", "DioramaClient", "DioramaEngine", "DioramaStore", "DioramaCore", "DioramaRunner", "DioramaTestSupport"]
        ),
    ]
)
