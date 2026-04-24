// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Keyfob",
    defaultLocalization: "en",
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
        .library(name: "KeyfobWebShared", targets: ["KeyfobWebShared"]),
        .library(name: "KeyfobRelay", targets: ["KeyfobRelay"])
    ],
    dependencies: [
        // Nostr SDK for iOS/macOS (secp256k1 + Nostr primitives)
        .package(url: "https://github.com/nostr-sdk/nostr-sdk-ios.git", from: "0.3.0"),
        // CryptoSwift for scrypt key derivation (NIP-49)
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.4"),
    ],
    targets: [
        .target(
            name: "KeyfobCrypto",
            dependencies: [
                .product(name: "NostrSDK", package: "nostr-sdk-ios"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
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
            path: "Sources/KeyfobWebShared",
            exclude: ["nostr-provider.ts"]
        ),
        .testTarget(
            name: "KeyfobWebSharedTests",
            dependencies: ["KeyfobWebShared"],
            path: "Tests/KeyfobWebSharedTests"
        ),
        .target(
            name: "KeyfobRelay",
            dependencies: [],
            path: "Sources/KeyfobRelay"
        ),
        .testTarget(
            name: "KeyfobRelayTests",
            dependencies: ["KeyfobRelay"],
            path: "Tests/KeyfobRelayTests"
        )
    ]
)
