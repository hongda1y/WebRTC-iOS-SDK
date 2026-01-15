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
        )
        // REMOVE the separate WebRTC product - it causes duplicate linking!
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.6")
    ],
    targets: [
        .target(
            name: "WebRTCiOSSDK",
            dependencies: [
                "Starscream",
                "WebRTC"
            ],
            path: "WebRTCiOSSDK"
            // REMOVE linkerSettings - not needed for binary targets
        ),
        .binaryTarget(
            name: "WebRTC",
            path: "WebRTC.xcframework"
        )
    ]
)
