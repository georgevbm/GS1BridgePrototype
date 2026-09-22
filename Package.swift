// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GS1BridgePrototype",
    products: [
        .library(name: "GS1Core", targets: ["GS1Core"])
    ],
    targets: [
        .target(name: "GS1Core"),
        .testTarget(name: "GS1CoreTests", dependencies: ["GS1Core"])
    ]
)
