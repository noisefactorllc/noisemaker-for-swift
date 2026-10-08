import AppKit
import MetalKit
import Testing
@testable import Noisemaker
@testable import NoisemakerMetalKit

@MainActor @Suite(.serialized)
struct MetalKitBootstrapGPUTests {
    @Test func sourceInitializerAppliesControlsAndPreservesCapabilityOnRebuild() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 128, height: 128), device: device)
        view.drawableSize = CGSize(width: 128, height: 128)
        let registry = try EffectRegistry.bundled()
        let source = "search synth\nnoise(octaves: frame, ridges: time, seed: time).write(o0)\nrender(o0)\n"
        let host = try NoisemakerViewRenderer(view: view, source: source,
            registry: registry, maximumTextureDimension2D: 8_192)
        let pass = try requireValue(host.renderer.graph.passes.first)
        expectEqual(pass.raw.field("uniforms")?.field("octaves")?.numberValue, 2)
        expectEqual(pass.raw.field("uniforms")?.field("seed")?.numberValue, 1)
        expectEqual(pass.raw.field("uniforms")?.field("ridges")?.boolValue, true)
        expectEqual(host.renderer.maximumTextureDimension2D, 8_192)
        try host.resize(to: RenderSize(width: 96, height: 96))
        expectEqual(host.renderer.maximumTextureDimension2D, 8_192)
        try host.updateParameter(stepIndex: 0, name: "seed", value: .number(3))
        expectEqual(host.renderer.maximumTextureDimension2D, 8_192)
        try host.replaceGraph(host.renderer.graph)
        expectEqual(host.renderer.maximumTextureDimension2D, 8_192)
    }

    @Test func externalPreparationSeesPublishedCapabilityClampedGraph() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64), device: device)
        view.drawableSize = CGSize(width: 64, height: 64)
        let registry = try EffectRegistry.bundled()
        let source = "search synth3d, render\nnoise3d(volumeSize: x128).render3d().write(o0)\nrender(o0)\n"
        let host = try NoisemakerViewRenderer(view: view, source: source,
            registry: registry, maximumTextureDimension2D: 8_192)
        var observed: [Double] = []
        try host.setExternalTexturesPreparation { graph, _ in
            let size = try requireValue(graph.passes.first?.raw.field("uniforms")?
                .field("volumeSize")?.numberValue)
            observed.append(size)
            return { _ in [:] }
        }
        let raw = try NoisemakerCompiler(registry: registry).compile(source: source)
        try host.replaceGraph(raw)
        try host.updateParameter(stepIndex: 0, name: "volumeSize", value: .number(128))
        expectEqual(observed, [64, 64, 64])
        expectEqual(host.renderer.graph.passes.first?.raw.field("uniforms")?
            .field("volumeSize")?.numberValue, 64)
    }
}
