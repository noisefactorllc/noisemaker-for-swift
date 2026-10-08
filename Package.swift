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
        .binaryTarget(name: "CNoisemakerRaster", path: "Artifacts/CNoisemakerRaster.xcframework"),
        .target(name: "Noisemaker", dependencies: ["CNoisemakerTint", "CNoisemakerRaster"],
                resources: [.process("Resources/catalog.json"), .copy("Resources/meshes")],
                linkerSettings: [.linkedLibrary("c++"),
                                 .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
                                 .linkedFramework("CoreGraphics", .when(platforms: [.macOS])),
                                 .linkedFramework("CoreText", .when(platforms: [.macOS]))]),
        .target(name: "NoisemakerMetalKit", dependencies: ["Noisemaker"]),
        .executableTarget(name: "NMRender", dependencies: ["Noisemaker"]),
        .executableTarget(name: "NMViewer", dependencies: ["Noisemaker", "NoisemakerMetalKit"]),
        .testTarget(name: "NoisemakerTests", dependencies: ["Noisemaker", "NoisemakerMetalKit"],
                    linkerSettings: [.linkedFramework("AppKit", .when(platforms: [.macOS]))]),
    ]
)
