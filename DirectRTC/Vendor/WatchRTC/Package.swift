// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "WatchRTC", platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
 products: [.library(name:"WatchRTC",targets:["WatchRTC"])],
 dependencies: [
  .package(url:"https://github.com/1amageek/swift-networking.git",exact:"0.1.0"),
  .package(url:"https://github.com/1amageek/swift-ssl.git",exact:"0.4.0"),
  .package(url:"https://github.com/1amageek/swift-tls.git",exact:"2.1.0"),
  .package(url:"https://github.com/apple/swift-log.git",exact:"1.15.1")
 ], targets:[.target(name:"WatchRTC",dependencies:[
  .product(name:"TLS",package:"swift-tls"),
  .product(name:"NetworkingCore",package:"swift-networking"),
  .product(name:"NetworkingTime",package:"swift-networking"),
  .product(name:"NetworkingPOSIX",package:"swift-networking"),
  .product(name:"NetworkingWASI",package:"swift-networking"),
  .product(name:"SSLCrypto",package:"swift-ssl"),
  .product(name:"SSLASN1",package:"swift-ssl"),
  .product(name:"SSLX509",package:"swift-ssl"),
  .product(name:"Logging",package:"swift-log")
 ],swiftSettings:[.enableExperimentalFeature("Lifetimes")])])
