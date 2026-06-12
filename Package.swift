// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptureStudio",
    platforms: [.macOS(.v15)],
    dependencies: [
        // 0.x builds from source on Command Line Tools (no bundled Testing module);
        // 6.x requires toolchain interop libs that CLT lacks.
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "CaptureStudio",
            path: "Sources/CaptureStudio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CaptureStudioTests",
            dependencies: [
                "CaptureStudio",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/CaptureStudioTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
