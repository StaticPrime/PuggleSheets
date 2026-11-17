// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PuggleSheetsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PuggleSheetsKit", targets: ["PuggleSheetsKit"]),
    ],
    targets: [
        .target(name: "PuggleSheetsKit"),
        .testTarget(name: "PuggleSheetsKitTests", dependencies: ["PuggleSheetsKit"]),
    ]
)
