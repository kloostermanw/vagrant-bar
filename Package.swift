// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VagrantBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VagrantCore"),
        .executableTarget(name: "VagrantBar", dependencies: ["VagrantCore"]),
        .testTarget(name: "VagrantCoreTests", dependencies: ["VagrantCore"]),
    ]
)
