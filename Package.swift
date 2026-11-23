// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptureStudio",
    platforms: [.macOS(.v15)],
    dependencies: [
        // 0.x builds from source on Command Line Tools (no bundled Testing module);
        // 6.x requires toolchain interop libs that CLT lacks.
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "0.12.0"),
        // Global hotkey via Carbon (no Accessibility/Input-Monitoring permission)
        // plus a SwiftUI recorder field + persistence. Pinned to 1.10.0: later
        // releases adopt the #Preview macro, whose plugin Command Line Tools
        // lacks (same constraint as the swift-testing 0.x pin above). 1.10.0 has
        // the same Name/onKeyUp/Recorder API we use.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.10.0"),
        // Auto-update (EdDSA-signed appcast on GitHub Releases). Binary
        // xcframework, so it builds under Command Line Tools too. The .app
        // bundle embeds Sparkle.framework in Contents/Frameworks (build-app.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "CaptureStudio",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
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
