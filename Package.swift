// swift-tools-version: 6.0
import PackageDescription

// The iOS app, as a package. Same three-target shape as the Mac app one
// directory up, for the same reasons — see docs/plan.md, "Shape".
//
// macOS is listed alongside iOS so `swift test` runs on the host without a
// simulator. Anything iOS-only sits behind `#if os(iOS)`.
let package = Package(
    name: "ClioMobile",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ClioMobileCore", targets: ["ClioMobileCore"]),
        .library(name: "ClioMobileUI", targets: ["ClioMobileUI"]),
        // The Live Activity's attributes, shared by the app and the widget
        // extension. Nothing else, so the extension stays small.
        .library(name: "ClioMobileActivity", targets: ["ClioMobileActivity"]),
    ],
    dependencies: [
        // CoreML Whisper with an Apple Neural Engine path. The same version
        // the Mac app pins, so the two engines behave the same.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
        // A language model on the phone's GPU, for titles and summaries
        // where Apple Intelligence is not there. Apple's own framework.
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.29.1"),
    ],
    targets: [
        // Everything that is not SwiftUI: settings, the library of
        // recordings, audio capture, the model manager, the WhisperKit
        // engine, formatting.
        .target(name: "ClioMobileCore",
                dependencies: [
                    "ClioMobileObjC",
                    .product(name: "WhisperKit", package: "WhisperKit"),
                ]),
        // One Objective-C function: run a block and catch the NSException
        // it may raise. AVAudioEngine throws them; Swift cannot catch them.
        .target(name: "ClioMobileObjC"),
        .target(name: "ClioMobileActivity"),
        // MLX, and nothing else: the core stays free of it, so `swift test`
        // and every preview keep building without a language model.
        .target(name: "ClioMobileSummary",
                dependencies: [
                    "ClioMobileCore",
                    .product(name: "MLXLLM", package: "mlx-swift-examples"),
                    .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                ]),
        // Every view, plus AppModel. A library so #Preview renders
        // dependably.
        .target(name: "ClioMobileUI",
                dependencies: ["ClioMobileCore", "ClioMobileActivity", "ClioMobileSummary"]),
        .testTarget(name: "ClioMobileCoreTests", dependencies: ["ClioMobileCore"]),
    ]
)
