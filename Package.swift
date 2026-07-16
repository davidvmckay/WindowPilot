// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowPilot",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "WindowPilot",
            dependencies: [
                "WindowPilotCore",
                "WindowPilotUI",
                "HotKey",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/App",
            linkerSettings: [
                // Bundle layout: WindowPilot.app/Contents/Frameworks/Sparkle.framework
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    // Dev layout: .build/debug/WindowPilot finds the SPM artifact
                    "-Xlinker", "-rpath", "-Xlinker",
                    "@loader_path/../artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64",
                ]),
            ]
        ),
        .executableTarget(
            name: "windowpilot-cli",
            dependencies: ["WindowPilotCore"],
            path: "Sources/CLI"
        ),
        .target(
            name: "WindowPilotCore",
            dependencies: [],
            path: "Sources/Core",
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
            ]
        ),
        .target(
            name: "WindowPilotUI",
            dependencies: ["WindowPilotCore"],
            path: "Sources/UI"
        ),
        .testTarget(
            name: "WindowPilotCoreTests",
            dependencies: ["WindowPilotCore"],
            path: "Tests/CoreTests"
        ),
        .testTarget(
            name: "WindowPilotIntegrationTests",
            dependencies: ["WindowPilotCore", "WindowPilotUI"],
            path: "Tests/IntegrationTests"
        ),
    ]
)
