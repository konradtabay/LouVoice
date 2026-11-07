// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LouVoice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LouVoice", targets: ["LouVoice"]),
        .executable(name: "LouVoiceCheck", targets: ["LouVoiceCheck"]),
    ],
    targets: [
        // Pure Swift: signal pipeline, recognizer, evaluation, gestures, simulator. No UI, no CoreMotion.
        .target(name: "LouVoiceCore"),
        // SwiftUI app. Wrapped into LouVoice.app by scripts/build-app.sh.
        .executableTarget(name: "LouVoice", dependencies: ["LouVoiceCore"]),
        // Self-test runner that works on Command Line Tools without XCTest.
        .executableTarget(name: "LouVoiceCheck", dependencies: ["LouVoiceCore"]),
        .testTarget(name: "LouVoiceCoreTests", dependencies: ["LouVoiceCore"]),
    ]
)
