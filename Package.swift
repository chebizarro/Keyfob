// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Keyfob",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "KeyfobCrypto", targets: ["KeyfobCrypto"]),
        .library(name: "KeyfobCore", targets: ["KeyfobCore"]),
        .library(name: "KeyfobPolicy", targets: ["KeyfobPolicy"]),
        .library(name: "KeyfobBridge", targets: ["KeyfobBridge"]),
        .library(name: "KeyfobUI", targets: ["KeyfobUI"]),
        .library(name: "KeyfobWebShared", targets: ["KeyfobWebShared"])
    ],
    dependencies: [
        // Nostr SDK for iOS/macOS (secp256k1 + Nostr primitives)
        .package(url: "https://github.com/nostr-sdk/nostr-sdk-ios.git", from: "0.3.0"),
    ],
    targets: [
        .target(
            name: "KeyfobCrypto",
            dependencies: [
                .product(name: "NostrSDK", package: "nostr-sdk-ios")
            ],
            path: "Sources/KeyfobCrypto"
        ),
        .testTarget(
            name: "KeyfobCryptoTests",
            dependencies: ["KeyfobCrypto"],
            path: "Tests/KeyfobCryptoTests"
        ),
        .target(
            name: "KeyfobCore",
            dependencies: ["KeyfobCrypto", "KeyfobPolicy"],
            path: "Sources/KeyfobCore"
        ),
        .testTarget(
            name: "KeyfobCoreTests",
            dependencies: ["KeyfobCore"],
            path: "Tests/KeyfobCoreTests"
        ),
        .target(
            name: "KeyfobPolicy",
            dependencies: [],
            path: "Sources/KeyfobPolicy"
        ),
        .testTarget(
            name: "KeyfobPolicyTests",
            dependencies: ["KeyfobPolicy"],
            path: "Tests/KeyfobPolicyTests"
        ),
        .target(
            name: "KeyfobBridge",
            dependencies: ["KeyfobCore", "KeyfobCrypto"],
            path: "Sources/KeyfobBridge"
        ),
        .testTarget(
            name: "KeyfobBridgeTests",
            dependencies: ["KeyfobBridge"],
            path: "Tests/KeyfobBridgeTests"
        ),
        .target(
            name: "KeyfobUI",
            dependencies: ["KeyfobCore"],
            path: "Sources/KeyfobUI",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "KeyfobUITests",
            dependencies: ["KeyfobUI"],
            path: "Tests/KeyfobUITests"
        ),
        .target(
            name: "KeyfobWebShared",
            dependencies: [],
            path: "Sources/KeyfobWebShared"
        ),
        .testTarget(
            name: "KeyfobWebSharedTests",
            dependencies: ["KeyfobWebShared"],
            path: "Tests/KeyfobWebSharedTests"
        )
    ]
)
