import Foundation
import Metal
import Testing
import CryptoKit
@testable import Noisemaker

@Suite(.serialized)
struct MipGPUTests {
    @Test func completeMipGraphMatchesLockedWebGL2Pixels() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let definition = #"{"name":"Mip Chain Probe","namespace":"user","func":"mipProbe","starter":true,"textures":{"patternTex":{"width":"screen","height":"screen","format":"rgba8unorm","mipmaps":true}},"passes":[{"name":"pattern","program":"pattern","inputs":{},"outputs":{"fragColor":"patternTex"}},{"name":"sample","program":"sample","inputs":{"inputTex":"patternTex"},"outputs":{"fragColor":"outputTex"}}]}"#
        let pattern = """
            @group(0) @binding(0) var<uniform> resolution: vec2<f32>;
            @fragment fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
                let x = u32(pixel.x); let y = u32(pixel.y);
                let red = select(0.0, 1.0, (x % 8u) < 4u);
                let green = select(0.0, 1.0, (y % 16u) < 8u);
                let blue = select(0.0, 1.0, ((x + y) & 1u) == 1u);
                return vec4<f32>(red, green, blue, 1.0);
            }
            """
        let sample = """
            @group(0) @binding(0) var<uniform> resolution: vec2<f32>;
            @group(0) @binding(1) var inputTex: texture_2d<f32>;
            @group(0) @binding(2) var inputSampler: sampler;
            @fragment fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
                let uv = pixel.xy / resolution;
                let lod = select(0.0, 3.0, uv.x >= 0.5);
                return textureSampleLevel(inputTex, inputSampler, uv, lod);
            }
            """
        var registry = try EffectRegistry.bundled()
        try registry.registerPortable(definitionJSON: Data(definition.utf8),
            orderedShaderSources: [("pattern", pattern), ("sample", sample)])
        let graph = try NoisemakerCompiler(registry: registry).compile(source:
            "search user\nmipProbe().write(o0)\nrender(o0)\n")
        let vertex = registry.defaultVertex
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 257, height: 129),
            defaultVertexWGSL: try requireValue(vertex.field("wgsl")?.stringValue),
            vertexEntryPoint: try requireValue(vertex.field("entryPoint")?.stringValue),
            registry: registry)
        let row = ((257 * 8 + 255) / 256) * 256
        var image = Data(count: 257 * 129 * 4)
        for index in 0..<8 {
            let command = try requireValue(queue.makeCommandBuffer())
            let lease = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
                frameIndex: UInt64(index)), into: command)
            var buffer: MTLBuffer?
            if index == 7 {
                buffer = try requireValue(device.makeBuffer(length: row * 129,
                    options: .storageModeShared))
                let blit = try requireValue(command.makeBlitCommandEncoder())
                blit.copy(from: lease.texture, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: 257, height: 129, depth: 1),
                    to: buffer!, destinationOffset: 0, destinationBytesPerRow: row,
                    destinationBytesPerImage: row * 129)
                blit.endEncoding()
            }
            command.commit()
            command.waitUntilCompleted()
            expectEqual(command.status, .completed, "\(String(describing: command.error))")
            if let error = command.error { throw error }
            if let buffer {
                let half = buffer.contents().assumingMemoryBound(to: UInt16.self)
                image.withUnsafeMutableBytes { bytes in
                    let output = bytes.bindMemory(to: UInt8.self)
                    for y in 0..<129 { for x in 0..<257 { for channel in 0..<4 {
                        let value = Float(Float16(bitPattern: half[y * row / 2 + x * 4 + channel]))
                        output[(y * 257 + x) * 4 + channel] = UInt8((max(0, min(1, value)) * 255).rounded())
                    } } }
                }
            }
        }
        let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        // Locked WebGL2 presented framebuffer, dual-language Portable probe,
        // 257x129 at frame 8. Its presenter has the same row orientation as
        // this raw Metal output (the nm-render CLI flips for WebGPU CanvasSink).
        expectEqual(hash, "406e198a522b809e6a61157fd717ce0d93cc67757e35f705d2ae986a334ff5b8")
    }

    // Expected levels were captured from locked WebGL2Backend.generateMipmaps
    // with gl.blitFramebuffer(..., gl.NEAREST) on the same source bytes.
    @Test func oddAndSingleColumnMipLevelsMatchWebGL2() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let generator = try MipGenerator(device: device,
            formats: Set([MTLPixelFormat.rgba8Unorm.rawValue]))
        let cases: [(width: Int, height: Int, expected: [[UInt8]])] = [
            (5, 3, [[41,31,46,255,123,31,80,255], [123,31,80,255]]),
            (1, 7, [[0,31,29,255,0,93,87,255,0,155,145,255],
                    [0,93,87,255]])
        ]
        for item in cases {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: item.width, height: item.height,
                mipmapped: true)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            let texture = try requireValue(device.makeTexture(descriptor: descriptor))
            var pixels = [UInt8](repeating: 0, count: item.width * item.height * 4)
            for y in 0..<item.height { for x in 0..<item.width {
                let offset = (y * item.width + x) * 4
                pixels[offset] = UInt8(x * 41)
                pixels[offset + 1] = UInt8(y * 31)
                pixels[offset + 2] = UInt8(x * 17 + y * 29)
                pixels[offset + 3] = 255
            } }
            pixels.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, item.width, item.height),
                    mipmapLevel: 0, withBytes: bytes.baseAddress!,
                    bytesPerRow: item.width * 4)
            }
            let command = try requireValue(queue.makeCommandBuffer())
            var retained: [AnyObject] = []
            try generator.encode(texture: texture, into: command, retained: &retained)
            command.commit()
            command.waitUntilCompleted()
            expectEqual(command.status, .completed, "\(String(describing: command.error))")
            if let error = command.error { throw error }
            for level in 1..<texture.mipmapLevelCount {
                let width = max(1, item.width >> level)
                let height = max(1, item.height >> level)
                var actual = [UInt8](repeating: 0, count: width * height * 4)
                actual.withUnsafeMutableBytes { bytes in
                    texture.getBytes(bytes.baseAddress!, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level)
                }
                expectEqual(actual, item.expected[level - 1])
            }
            _ = retained
        }
    }
}
