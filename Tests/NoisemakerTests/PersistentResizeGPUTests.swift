import CryptoKit
import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct PersistentResizeGPUTests {
    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private let definition = #"{"name":"Persistent Graph Probe","namespace":"user","func":"persistentGraphProbe","starter":true,"textures":{"patternTex":{"width":"screen","height":"screen","format":"rgba8unorm","persistent":true},"outputTex":{"width":"screen","height":"screen","format":"rgba8unorm"}},"passes":[{"name":"pattern","program":"pattern","inputs":{},"outputs":{"fragColor":"patternTex"},"conditions":{"runIf":[{"uniform":"frame","equals":0}]}},{"name":"sample","program":"sample","inputs":{"inputTex":"patternTex"},"outputs":{"fragColor":"outputTex"}}]}"#
    private let pattern = """
        @group(0) @binding(0) var<uniform> resolution: vec2<f32>;
        @fragment fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
            let x = u32(pixel.x); let y = u32(pixel.y);
            let red = select(0.0, 1.0, (x % 8u) < 4u);
            let green = select(0.0, 1.0, (y % 16u) < 8u);
            let blue = select(0.0, 1.0, ((x + y) & 1u) == 1u);
            return vec4<f32>(red, green, blue, 1.0);
        }
        """
    private let sample = """
        @group(0) @binding(0) var<uniform> resolution: vec2<f32>;
        @group(0) @binding(1) var inputTex: texture_2d<f32>;
        @group(0) @binding(2) var inputSampler: sampler;
        @fragment fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
            let uv = pixel.xy / resolution;
            let lod = select(0.0, 3.0, uv.x >= 0.5);
            return textureSampleLevel(inputTex, inputSampler, uv, lod);
        }
        """

    private func raw(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> Data {
        let pixelBytes: Int
        switch texture.pixelFormat {
        case .rgba8Unorm: pixelBytes = 4
        case .rgba16Float: pixelBytes = 8
        default: throw GraphDiagnostic.unsupported("persistent probe readback format")
        }
        let row = ((texture.width * pixelBytes + 255) / 256) * 256
        let buffer = try requireValue(queue.device.makeBuffer(length: row * texture.height,
            options: .storageModeShared))
        let command = try requireValue(queue.makeCommandBuffer())
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: row,
            destinationBytesPerImage: row * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        var result = Data()
        for y in 0..<texture.height {
            result.append(buffer.contents().advanced(by: y * row)
                .assumingMemoryBound(to: UInt8.self), count: texture.width * pixelBytes)
        }
        return result
    }

    @Test func nextFrameConsumesHistoryPreservedAcrossOddResize() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        var registry = try EffectRegistry.bundled()
        try registry.registerPortable(definitionJSON: Data(definition.utf8),
            orderedShaderSources: [("pattern", pattern), ("sample", sample)])
        let graph = try NoisemakerCompiler(registry: registry).compile(source:
            "search user\npersistentGraphProbe().write(o0)\nrender(o0)\n")
        let vertex = registry.defaultVertex
        func renderer(_ width: Int, _ height: Int) throws -> NoisemakerRenderer {
            try NoisemakerRenderer(device: device, graph: graph,
                size: RenderSize(width: width, height: height),
                defaultVertexWGSL: requireValue(vertex.field("wgsl")?.stringValue),
                vertexEntryPoint: requireValue(vertex.field("entryPoint")?.stringValue),
                registry: registry)
        }
        let old = try renderer(257, 129)
        let firstCommand = try requireValue(queue.makeCommandBuffer())
        let first = try old.encode(frame: FrameState(time: 0.25, delta: 0, frameIndex: 0),
            into: firstCommand)
        firstCommand.commit()
        firstCommand.waitUntilCompleted()
        expectEqual(firstCommand.status, .completed)
        if let error = firstCommand.error { throw error }
        let original = try requireValue(first.graphTexture("node_0_patternTex"))
        expectEqual(sha(try raw(original, queue: queue)),
            "dcfab3f573678d37c2acaca9c04c68956f6a84ebf0bb5beb0a027ad3eb2eed90")

        let resized = try renderer(129, 65)
        try resized.adoptFeedback(from: old)
        let secondCommand = try requireValue(queue.makeCommandBuffer())
        let second = try resized.encode(frame: FrameState(time: 0.25, delta: 0,
            frameIndex: 1), into: secondCommand)
        secondCommand.commit()
        secondCommand.waitUntilCompleted()
        expectEqual(secondCommand.status, .completed)
        if let error = secondCommand.error { throw error }
        let preserved = try requireValue(second.graphTexture("node_0_patternTex"))
        let sampled = try requireValue(second.graphTexture("node_0_out"))
        // Source-authored Portable probe, corrected center-nearest WebGPU
        // diagnostic runtime. The locked WebGPU resize shader currently fails.
        expectEqual(sha(try raw(preserved, queue: queue)),
            "8adb900ba40c8cf776b3b39e4ea983ebcd884ba3a91648030d1f67d50f450dd3")
        expectEqual(sha(try raw(sampled, queue: queue)),
            "bdd6df8053f6526c09dbdac1401d7ba43d6c68d86ed4a098e643898de147ce92")
        expectEqual(sha(try raw(original, queue: queue)),
            "dcfab3f573678d37c2acaca9c04c68956f6a84ebf0bb5beb0a027ad3eb2eed90")
    }

    @Test func ordinaryTextureSurvivesSkippedWriterOnNextFrame() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        var registry = try EffectRegistry.bundled()
        let ordinary = definition.replacingOccurrences(of: #""persistent":true"#,
            with: #""persistent":false"#)
        try registry.registerPortable(definitionJSON: Data(ordinary.utf8),
            orderedShaderSources: [("pattern", pattern), ("sample", sample)])
        let graph = try NoisemakerCompiler(registry: registry).compile(source:
            "search user\npersistentGraphProbe().write(o0)\nrender(o0)\n")
        let vertex = registry.defaultVertex
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 17, height: 9),
            defaultVertexWGSL: requireValue(vertex.field("wgsl")?.stringValue),
            vertexEntryPoint: requireValue(vertex.field("entryPoint")?.stringValue),
            registry: registry)
        func encode(_ index: UInt64) throws -> OutputLease {
            let command = try requireValue(queue.makeCommandBuffer())
            let lease = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
                frameIndex: index), into: command)
            command.commit()
            command.waitUntilCompleted()
            expectEqual(command.status, .completed)
            if let error = command.error { throw error }
            return lease
        }
        let first = try encode(0)
        let pattern0 = try requireValue(first.graphTexture("node_0_patternTex"))
        let output0 = try requireValue(first.graphTexture("node_0_outputTex"))
        let patternHash = sha(try raw(pattern0, queue: queue))
        let outputHash = sha(try raw(output0, queue: queue))
        let second = try encode(1)
        let pattern1 = try requireValue(second.graphTexture("node_0_patternTex"))
        let output1 = try requireValue(second.graphTexture("node_0_outputTex"))
        expectEqual(sha(try raw(pattern1, queue: queue)), patternHash)
        expectEqual(sha(try raw(output1, queue: queue)), outputHash)
    }

    @Test func ordinaryTextureLoadPreservesDiscardedPixels() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        var registry = try EffectRegistry.bundled()
        let ordinary = definition.replacingOccurrences(of: #""persistent":true"#,
            with: #""persistent":false"#).replacingOccurrences(of:
            #","conditions":{"runIf":[{"uniform":"frame","equals":0}]}"#, with: "")
        let writer = """
            @group(0) @binding(0) var<uniform> frame: f32;
            @fragment fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
                if (frame > 0.5) {
                    if (pixel.x < 8.0) { discard; }
                    return vec4<f32>(0.0, 0.0, 1.0, 1.0);
                }
                return vec4<f32>(1.0, 0.0, 0.0, 1.0);
            }
            """
        let reader = """
            @group(0) @binding(0) var<uniform> resolution: vec2<f32>;
            @group(0) @binding(1) var inputTex: texture_2d<f32>;
            @fragment fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
                return textureLoad(inputTex, vec2<i32>(pixel.xy), 0);
            }
            """
        try registry.registerPortable(definitionJSON: Data(ordinary.utf8),
            orderedShaderSources: [("pattern", writer), ("sample", reader)])
        let graph = try NoisemakerCompiler(registry: registry).compile(source:
            "search user\npersistentGraphProbe().write(o0)\nrender(o0)\n")
        let vertex = registry.defaultVertex
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 16, height: 8),
            defaultVertexWGSL: requireValue(vertex.field("wgsl")?.stringValue),
            vertexEntryPoint: requireValue(vertex.field("entryPoint")?.stringValue),
            registry: registry)
        for index in 0...1 {
            let command = try requireValue(queue.makeCommandBuffer())
            let lease = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
                frameIndex: UInt64(index)), into: command)
            command.commit()
            command.waitUntilCompleted()
            expectEqual(command.status, .completed)
            if let error = command.error { throw error }
            if index == 1 {
                let history = try requireValue(lease.graphTexture("node_0_patternTex"))
                let output = try requireValue(lease.graphTexture("node_0_out"))
                let expected = Data((0..<(16 * 8)).flatMap { pixel in
                    pixel % 16 < 8 ? [UInt8(255), 0, 0, 255] : [0, 0, 255, 255]
                })
                expectEqual(try raw(history, queue: queue), expected)
                let expectedOutput = Data((0..<(16 * 8)).flatMap { pixel in
                    pixel % 16 < 8 ? [UInt8(0), 60, 0, 0, 0, 0, 0, 60] :
                        [0, 0, 0, 0, 0, 60, 0, 60]
                })
                expectEqual(try raw(output, queue: queue), expectedOutput)
            }
        }
    }
}
