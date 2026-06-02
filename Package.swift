// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "local-dictation", targets: ["LocalDictation"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "LocalDictation",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/LocalDictation"
        )
    ]
)
