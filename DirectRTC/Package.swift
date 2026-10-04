// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DirectRTC",
    platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
    products: [.library(name: "DirectRTC", targets: ["DirectRTC"])],
    dependencies: [.package(path: "Vendor/WatchRTC")],
    targets: [
        .target(name: "DirectRTC", dependencies: [
            .product(name: "WatchRTC", package: "WatchRTC")
        ]),
        .executableTarget(name: "RTCProbe", dependencies: ["DirectRTC"]),
        .testTarget(name: "DirectRTCTests", dependencies: ["DirectRTC"])
    ]
)
