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
    ],
    dependencies: [
        // CoreML Whisper with an Apple Neural Engine path. The same version
        // the Mac app pins, so the two engines behave the same.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0"),
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
        // Every view, plus AppModel. A library so #Preview renders
        // dependably.
        .target(name: "ClioMobileUI", dependencies: ["ClioMobileCore"]),
        .testTarget(name: "ClioMobileCoreTests", dependencies: ["ClioMobileCore"]),
    ]
)
