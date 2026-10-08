// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Noisemaker",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Noisemaker", targets: ["Noisemaker"]),
               .library(name: "NoisemakerMetalKit", targets: ["NoisemakerMetalKit"]),
               .executable(name: "nm-render", targets: ["NMRender"]),
               .executable(name: "nm-viewer", targets: ["NMViewer"])],
    targets: [
        .binaryTarget(name: "CNoisemakerTint", path: "Artifacts/CNoisemakerTint.xcframework"),
        .target(name: "Noisemaker", dependencies: ["CNoisemakerTint"],
                resources: [.process("Resources/catalog.json"), .copy("Resources/meshes")],
                linkerSettings: [.linkedLibrary("c++")]),
        .target(name: "NoisemakerMetalKit", dependencies: ["Noisemaker"]),
        .executableTarget(name: "NMRender", dependencies: ["Noisemaker"]),
        .executableTarget(name: "NMViewer", dependencies: ["Noisemaker", "NoisemakerMetalKit"]),
        .testTarget(name: "NoisemakerTests", dependencies: ["Noisemaker", "NoisemakerMetalKit"],
                    linkerSettings: [.linkedFramework("AppKit", .when(platforms: [.macOS]))]),
    ]
)
