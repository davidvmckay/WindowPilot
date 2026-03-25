// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowPilot",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "WindowPilot",
            dependencies: [
                "WindowPilotCore",
                "WindowPilotUI",
                "HotKey",
            ],
            path: "Sources/App"
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
