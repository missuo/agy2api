// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "agy2api",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agy2api", targets: ["agy2api"]),
        .library(name: "Agy2APICore", targets: ["Agy2APICore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Agy2APICore",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "agy2api",
            dependencies: ["Agy2APICore", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "Agy2APICoreTests", dependencies: ["Agy2APICore"]),
    ],
    swiftLanguageModes: [.v6]
)
