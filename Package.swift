// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shoji",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "shoji", targets: ["Shoji"])
    ],
    targets: [
        .executableTarget(
            name: "Shoji",
            path: "Sources/Shoji",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
