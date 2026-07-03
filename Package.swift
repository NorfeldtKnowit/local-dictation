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
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4")
    ],
    targets: [
        .executableTarget(
            name: "LocalDictation",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/LocalDictation"
        )
    ]
)
