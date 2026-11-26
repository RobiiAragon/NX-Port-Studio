// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NXPortStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NXPortStudio", targets: ["PortStudio"]),
               .executable(name: "NXPortStudioAgent", targets: ["PortStudioAgent"])],
    targets: [
        .target(name: "CLANRelay", publicHeadersPath: "include"),
        .target(name: "CSaveArchive", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("archive")]),
        .target(name: "PortCore", dependencies: ["CLANRelay", "CSaveArchive"]),
        .executableTarget(name: "PortStudio", dependencies: ["PortCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "PortStudioAgent", dependencies: ["PortCore"]),
        .testTarget(name: "PortCoreTests", dependencies: ["PortCore"]),
        .testTarget(name: "PortStudioTests", dependencies: ["PortStudio", "PortCore"])
    ],
    swiftLanguageModes: [.v6]
)
