import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct PortableTextureGPUTests {
    private func makeRenderer(_ definition: String, shaders: [(String, String)],
                              size: Int = 16, limit: Int? = nil) throws -> NoisemakerRenderer {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        var registry = try EffectRegistry.bundled()
        try registry.registerPortable(definitionJSON: Data(definition.utf8), orderedShaderSources: shaders)
        let graph = try NoisemakerCompiler(registry: registry).compile(source:
            "search user\ntextureProbe().write(o0)\nrender(o0)\n")
        return try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: size, height: size),
            defaultVertexWGSL: try requireValue(registry.defaultVertex.field("wgsl")?.stringValue),
            registry: registry, maximumTextureDimension2D: limit)
    }

    private func pixels(_ renderer: NoisemakerRenderer, inputs: [String: MTLTexture] = [:], queue suppliedQueue: MTLCommandQueue? = nil) throws -> [Float] {
        let device = renderer.device
        let queue = try suppliedQueue ?? requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let output = try renderer.encode(into: command, externalTextures: inputs)
        let row = ((output.texture.width * 8 + 255) / 256) * 256
        let staging = try requireValue(device.makeBuffer(length: row * output.texture.height, options: .storageModeShared))
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: output.texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: output.texture.width, height: output.texture.height, depth: 1),
            to: staging, destinationOffset: 0, destinationBytesPerRow: row,
            destinationBytesPerImage: row * output.texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let words = staging.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<output.texture.width).flatMap { x in
            (0..<4).map { Float(Float16(bitPattern: words[8 * row / 2 + x * 4 + $0])) }
        }
    }

    @Test func enlargedSingleChannelIntermediatesPreserveNonuniformRed() throws {
        for format in ["r8", "r8unorm", "r16f", "r16float", "r32f", "r32float"] {
            let definition = #"{"name":"Texture Probe","namespace":"user","func":"textureProbe","textures":{"mask":{"width":"200%","height":"200%","format":"FORMAT","persistent":true,"mipmaps":true}},"passes":[{"program":"mask","outputs":{"fragColor":"mask"}},{"program":"show","inputs":{"maskTex":"mask"},"outputs":{"fragColor":"outputTex"}}]}"#.replacingOccurrences(of: "FORMAT", with: format)
            let mask = """
                @fragment fn main(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {
                    return vec4<f32>(p.x / 32.0, 0.8, 0.6, 0.2);
                }
                """
            let show = """
                @group(0) @binding(0) var maskTex: texture_2d<f32>;
                @fragment fn main(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {
                    return textureLoad(maskTex, vec2<i32>(i32(p.x) * 2, i32(p.y) * 2), 0);
                }
                """
            let renderer = try makeRenderer(definition, shaders: [("mask", mask), ("show", show)])
            let queue = try requireValue(renderer.device.makeCommandQueue())
            let values = try pixels(renderer, queue: queue)
            for x in [0, 5, 15] {
                expectLess(abs(values[x * 4] - (Float(x * 2) + 0.5) / 32), 0.005, format)
                expectEqual(values[x * 4 + 1], 0)
                expectEqual(values[x * 4 + 2], 0)
                expectEqual(values[x * 4 + 3], 1)
            }
            // Reuse persistent allocation and mip chain on another frame.
            expectEqual(try pixels(renderer, queue: queue), values)
            expectThrows(try makeRenderer(definition, shaders: [("mask", mask), ("show", show)], size: 200, limit: 256))
        }
    }

    @Test func externalDefaultsAndAuthoredSamplerBindingsMatchSource() throws {
        for (mode, uv, red) in [("implicit", 0.53125, Float(0.4375)),
                                ("default", 0.53125, Float(0.4375)),
                                ("nearest", 0.53125, Float(0)),
                                ("repeat", 1.25, Float(1)),
                                ("mipmap", 0.53125, Float(0.4375))] {
            let override = mode == "implicit" ? "" : #", "samplerTypes":{"imageSampler":"MODE"}"#.replacingOccurrences(of: "MODE", with: mode)
            let definition = #"{"name":"Texture Probe","namespace":"user","func":"textureProbe","externalTexture":"imageTex","passes":[{"program":"show","inputs":{"imageTex":"imageTex"},"outputs":{"fragColor":"outputTex"}OVERRIDE}]}"#.replacingOccurrences(of: "OVERRIDE", with: override)
            let shader = """
                @group(0) @binding(0) var imageTex: texture_2d<f32>;
                @group(0) @binding(1) var imageSampler: sampler;
                @fragment fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
                    return textureSample(imageTex, imageSampler, vec2<f32>(\(uv), 0.5));
                }
                """
            let renderer = try makeRenderer(definition, shaders: [("show", shader)])
            let texture = try TextureInput.rgba8(device: renderer.device,
                pixels: Data([255,0,0,255,0,0,255,255,255,0,0,255,0,0,255,255]),
                size: RenderSize(width: 2, height: 2))
            let name = try requireValue(renderer.graph.externalTextureNames.first)
            let values = try pixels(renderer, inputs: [name: texture])
            expectLess(abs(values[0] - red), 0.002, mode)
            expectLess(abs(values[2] - (1-red)), 0.002, mode)
        }
    }
}
