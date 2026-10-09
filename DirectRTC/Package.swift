// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DirectRTC",
    platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
    products: [.library(name: "DirectRTC", targets: ["DirectRTC"]), .executable(name: "PacketReplay", targets: ["PacketReplay"])],
    dependencies: [.package(path: "Vendor/WatchRTC")],
    targets: [
        .binaryTarget(name: "CDotNetEq", path: "Vendor/NetEqNative/NetEqNative.xcframework"),
        .target(name: "DirectRTC", dependencies: [
            "CDotNetEq",
            .product(name: "WatchRTC", package: "WatchRTC")
        ], linkerSettings: [.linkedLibrary("c++")]),
        .executableTarget(name: "RTCProbe", dependencies: ["DirectRTC"]),
        .executableTarget(name: "PacketReplay", dependencies: ["DirectRTC"]),
        .testTarget(name: "DirectRTCTests", dependencies: ["DirectRTC"])
    ]
)
