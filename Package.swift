// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "local-dictation", targets: ["LocalDictation"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
        // Exact pins per the 2026-07-07 supply-chain review (Apple's ml-explore
        // org; graph locked via the now-committed Package.resolved).
        // 0.29.1 (not the newest 0.31.x): the newest TAGGED examples release
        // (2.29.1) requires mlx-swift 0.29.x — only examples' untagged HEAD
        // moved to 0.31. Exact tag pairs beat tracking a branch.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.29.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.29.1")
    ],
    targets: [
        .executableTarget(
            name: "LocalDictation",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples")
            ],
            path: "Sources/LocalDictation"
        ),
        .testTarget(
            name: "LocalDictationTests",
            dependencies: ["LocalDictation"],
            path: "Tests/LocalDictationTests"
        )
    ]
)
