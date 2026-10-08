import Foundation
import MetalKit
import Testing
@testable import Noisemaker
@testable import NoisemakerMetalKit

@Suite(.serialized)
struct MetalKitParameterUpdateGPUTests {
    @MainActor private func makeHost(_ source: String, size: RenderSize? = nil) throws
        -> NoisemakerViewRenderer {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let size = try size ?? RenderSize(width: 65, height: 33)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height), device: device)
        view.isPaused = true
        view.drawableSize = CGSize(width: size.width, height: size.height)
        let registry = try EffectRegistry.bundled()
        let graph = try NoisemakerCompiler(registry: registry).compile(source: source)
        return try NoisemakerViewRenderer(view: view, graph: graph, registry: registry)
    }

    @MainActor @Test func selectedStepUpdateKeepsClockAndFailedUpdateKeepsRenderer() throws {
        let host = try makeHost("search synth\nsolid(color: #ff0000).write(o0)\nrender(o0)\n")
        let original = host.renderer
        _ = host.clock.next(at: 100, index: 0)
        _ = host.clock.next(at: 101, index: 1)
        try host.updateParameter(stepIndex: 0, name: "color", value: .string("#00ff00"))
        expectFalse(host.renderer === original)
        expectEqual(host.renderer.size.width, 65)
        expectEqual(host.renderer.graph.passes[0].uniforms.first(where: { $0.name == "color" })?
            .value.arrayValue?.first?.numberValue, 0)
        let resumed = host.clock.next(at: 102, index: 2)
        expectEqual(resumed.time, 0.2, accuracy: 0.00001)
        expectEqual(resumed.delta, 0.1, accuracy: 0.00001)
        expectEqual(host.frameIndex, 0)

        let active = host.renderer
        try host.updateParameter(stepIndex: 0, name: "color",
            value: .object([GraphField(name: "type", value: .string("Oscillator"))]))
        expectTrue(host.renderer === active, "source automation-controlled no-op must retain feedback")
        expectThrows(try host.updateParameter(stepIndex: 0, name: "color", value: .string("#bad")))
        expectTrue(host.renderer === active)
        expectThrows(try host.updateParameter(stepIndex: 0, name: "missing", value: .number(1)))
        expectTrue(host.renderer === active)
    }

    @MainActor @Test func externalTexturePreparationPublishesOnlyAfterSuccessfulUpdate() throws {
        let host = try makeHost("search synth\nmedia().write(o0)\nrender(o0)\n")
        let device = host.renderer.device
        var generation = 0
        var refusePreparation = false
        try host.setExternalTexturesPreparation { _, size in
            if refusePreparation { throw GraphDiagnostic.invalid("external preparation refused") }
            generation += 1
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: size.width, height: size.height, mipmapped: false)
            descriptor.usage = .shaderRead
            let texture = try requireValue(device.makeTexture(descriptor: descriptor))
            texture.label = "generation-\(generation)"
            return { _ in ["node_0_out": texture] }
        }
        expectEqual(generation, 1)
        let initial = host.renderer
        let initialTexture = try requireValue(host.externalTexturesProvider?(.zero)["node_0_out"])
        try host.updateParameter(stepIndex: 0, name: "imageSize",
                                 value: .array([.number(65), .number(33)]))
        expectFalse(host.renderer === initial)
        expectEqual(generation, 2)
        let updatedTexture = try requireValue(host.externalTexturesProvider?(.zero)["node_0_out"])
        expectFalse(initialTexture === updatedTexture)
        try host.updateParameter(stepIndex: 0, name: "imageSize",
            value: .array([.number(.infinity), .number(33)]))
        expectEqual(generation, 3)
        let infiniteSize = host.renderer.graph.passes[0].uniforms.first {
            $0.name == "imageSize"
        }?.value.arrayValue?.first?.numberValue
        expectTrue(infiniteSize?.isInfinite == true)
        let infiniteTexture = try requireValue(host.externalTexturesProvider?(.zero)["node_0_out"])
        expectFalse(infiniteTexture === updatedTexture)
        let active = host.renderer
        refusePreparation = true
        expectThrows(try host.updateParameter(stepIndex: 0, name: "imageSize",
            value: .array([.number(64), .number(32)])))
        expectTrue(host.renderer === active)
        expectEqual(generation, 3)
        expectTrue(try host.externalTexturesProvider?(.zero)["node_0_out"] === infiniteTexture)
        refusePreparation = false
        try host.resize(to: RenderSize(width: 33, height: 17))
        expectEqual(generation, 4)
        let resizedTexture = try requireValue(host.externalTexturesProvider?(.zero)["node_0_out"])
        expectEqual(resizedTexture.width, 33)
        expectEqual(resizedTexture.height, 17)

        let withoutPreparation = try makeHost("search synth\nmedia().write(o0)\nrender(o0)\n")
        let untouched = withoutPreparation.renderer
        expectThrows(try withoutPreparation.updateParameter(stepIndex: 0, name: "imageSize",
            value: .array([.number(33), .number(17)])))
        expectTrue(withoutPreparation.renderer === untouched)
    }
}
