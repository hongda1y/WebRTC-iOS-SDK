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
        // WebRTC available separately for apps that want direct access
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
                "WebRTC"
            ],
            path: "WebRTCiOSSDK"
        ),
        // Binary WebRTC framework (now signed)
        .binaryTarget(
            name: "WebRTC",
            path: "WebRTC.xcframework"
        )
    ]
)
