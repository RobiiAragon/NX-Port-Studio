// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NXPortStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NXPortStudio", targets: ["PortStudio"])],
    targets: [
        .target(name: "CLANRelay", publicHeadersPath: "include"),
        .target(name: "PortCore", dependencies: ["CLANRelay"]),
        .executableTarget(name: "PortStudio", dependencies: ["PortCore"], resources: [.copy("Resources")]),
        .testTarget(name: "PortCoreTests", dependencies: ["PortCore"]),
        .testTarget(name: "PortStudioTests", dependencies: ["PortStudio", "PortCore"])
    ],
    swiftLanguageModes: [.v6]
)
