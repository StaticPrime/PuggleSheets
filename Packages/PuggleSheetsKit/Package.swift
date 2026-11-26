// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PuggleSheetsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PuggleSheetsKit", targets: ["PuggleSheetsKit"]),
        // Keeping the app up to date: shared by the app and its update installer service.
        .library(name: "PuggleUpdate", targets: ["PuggleUpdate"]),
    ],
    targets: [
        .target(name: "PuggleSheetsKit"),
        .target(name: "PuggleUpdate"),
        .testTarget(name: "PuggleSheetsKitTests", dependencies: ["PuggleSheetsKit"]),
        .testTarget(name: "PuggleUpdateTests", dependencies: ["PuggleUpdate"]),
    ]
)
