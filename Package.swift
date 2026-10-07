// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Noisemaker",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Noisemaker", targets: ["Noisemaker"]),
               .executable(name: "nm-render", targets: ["NMRender"])],
    targets: [
        .binaryTarget(name: "CNoisemakerTint", path: ".build/tint/CNoisemakerTint.xcframework"),
        .target(name: "Noisemaker", dependencies: ["CNoisemakerTint"],
                linkerSettings: [.linkedLibrary("c++")]),
        .executableTarget(name: "NMRender", dependencies: ["Noisemaker"]),
        .testTarget(name: "NoisemakerTests", dependencies: ["Noisemaker"]),
    ]
)
