// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UnnamedKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "UnnamedKit", targets: ["UnnamedKit"]),
    ],
    targets: [
        .target(name: "UnnamedKit"),
        .testTarget(name: "UnnamedKitTests", dependencies: ["UnnamedKit"]),
    ]
)
