// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "WebRTCiOSSDK",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        // Your SDK product (apps import this)
        .library(
            name: "WebRTCiOSSDK",
            targets: ["WebRTCiOSSDK"]
        ),
        // Optional: expose WebRTC directly for apps that want it
        .library(
            name: "WebRTC",
            targets: ["WebRTC"]
        )
    ],
    dependencies: [
        // Third-party dependency
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.6")
    ],
    targets: [
        // SDK target
        .target(
            name: "WebRTCiOSSDK",
            dependencies: [
                "Starscream",
                "WebRTC"       // link WebRTC to SDK
            ],
            path: "WebRTCiOSSDK",
            linkerSettings: [
                // Ensure dynamic linking
                .linkedFramework("WebRTC", .when(platforms: [.iOS]))
            ]
        ),

        // Binary WebRTC framework
        .binaryTarget(
            name: "WebRTC",
            path: "WebRTC.xcframework"
        )
    ]
)
