import CryptoKit
import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct PortableStorageVolumeGPUTests {
    private let definition = #"{"name":"Storage 3D Probe","namespace":"user","func":"storage3dProbe","starter":true,"textures3d":{"volume":{"width":8,"height":8,"depth":8,"format":"rgba8unorm"}},"passes":[{"name":"fill","type":"compute","program":"fill","workgroups":[2,2,2],"storageTextures":{"volumeOut":"node_0_volume"}},{"name":"show","program":"show","inputs":{"volTex":"volume"},"outputs":{"fragColor":"outputTex"}}]}"#
    private let fill = """
        @group(0) @binding(0) var volumeOut: texture_storage_3d<rgba8unorm, write>;
        @compute @workgroup_size(4, 4, 4)
        fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
          if (any(gid >= vec3<u32>(8u, 8u, 8u))) { return; }
          textureStore(volumeOut, vec3<i32>(gid), vec4<f32>(f32(gid.x) / 7.0, f32(gid.y) / 7.0, f32(gid.z) / 7.0, 1.0));
        }
        """
    private let show = """
        @group(0) @binding(0) var volTex: texture_3d<f32>;
        @fragment
        fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
          let x = i32(pixel.x) % 8;
          let y = i32(pixel.y) % 8;
          let z = (i32(pixel.x) / 32 + i32(pixel.y) / 32) % 8;
          return textureLoad(volTex, vec3<i32>(x, y, z), 0);
        }
        """
    private let source = "search user\nstorage3dProbe().write(o0)\nrender(o0)\n"

    private func fixture(device: MTLDevice, definition: String? = nil,
                         fill: String? = nil) throws -> NoisemakerRenderer {
        var registry = try EffectRegistry.bundled()
        try registry.registerPortable(definitionJSON: Data((definition ?? self.definition).utf8),
            orderedShaderSources: [("fill", fill ?? self.fill), ("show", show)])
        let graph = try NoisemakerCompiler(registry: registry).compile(source: source)
        expectEqual(graph.passes[0].outputs.count, 0)
        expectTrue(graph.persistentTextureNames.contains("node_0_volume"))
        return try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 256, height: 256),
            defaultVertexWGSL: try requireValue(registry.defaultVertex.field("wgsl")?.stringValue),
            registry: registry)
    }

    private func readVolume(_ texture: MTLTexture, into command: MTLCommandBuffer,
                            device: MTLDevice) throws -> MTLBuffer {
        expectEqual(texture.textureType, .type3D)
        expectEqual(texture.width, 8)
        expectEqual(texture.height, 8)
        expectEqual(texture.depth, 8)
        let rowBytes = 256, imageBytes = rowBytes * 8
        let buffer = try requireValue(device.makeBuffer(length: imageBytes * 8,
            options: .storageModeShared))
        memset(buffer.contents(), 0, imageBytes * 8)
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 8, height: 8, depth: 8),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: imageBytes)
        blit.endEncoding()
        return buffer
    }

    @Test func internallyWrittenVolumeRejectsHostReplacementBeforeEncoding() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try fixture(device: device)
        let queue = try requireValue(device.makeCommandQueue())
        let usages: [MTLTextureUsage] = [.shaderRead, [.shaderRead, .shaderWrite]]
        for usage in usages {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .rgba8Unorm
            descriptor.width = 8
            descriptor.height = 8
            descriptor.depth = 8
            descriptor.storageMode = .shared
            descriptor.usage = usage
            let supplied = try requireValue(device.makeTexture(descriptor: descriptor))
            let command = try requireValue(queue.makeCommandBuffer())
            expectThrows(try renderer.encode(into: command,
                externalTextures: ["node_0_volume": supplied]),
                "source-owned storage output must not accept an external replacement")
            expectEqual(command.status, .notEnqueued)
        }
    }

    @Test func formattedStorageDeclarationUsesActualMetalWorkgroup() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let formatted = fill.replacingOccurrences(of: "texture_storage_3d<rgba8unorm, write>",
            with: "texture_storage_3d < rgba8unorm,\n\twrite >")
        let renderer = try fixture(device: device, fill: formatted)
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let output = try renderer.encode(into: command)
        let volume = try requireValue(output.graphTexture("node_0_volume"))
        let readback = try readVolume(volume, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let bytes = readback.contents().assumingMemoryBound(to: UInt8.self)
        let farCorner = 7 * 256 * 8 + 7 * 256 + 7 * 4
        expectEqual(bytes[farCorner], 255)
        expectEqual(bytes[farCorner + 1], 255)
        expectEqual(bytes[farCorner + 2], 255)
        expectEqual(bytes[farCorner + 3], 255)
    }

    @Test func storageComputeSamplesThreeDimensionalInput() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let samplingDefinition = #"{"name":"Storage 3D Probe","namespace":"user","func":"storage3dProbe","starter":true,"textures3d":{"source":{"width":8,"height":8,"depth":8,"format":"rgba8unorm","filter":"linear"},"volume":{"width":8,"height":8,"depth":8,"format":"rgba8unorm"}},"passes":[{"name":"fill","type":"compute","program":"fill","inputs":{"seedTex":"source"},"workgroups":[2,2,2],"storageTextures":{"volumeOut":"node_0_volume"}},{"name":"show","program":"show","inputs":{"volTex":"volume"},"outputs":{"fragColor":"outputTex"}}]}"#
        let samplingFill = """
            @group(0) @binding(0) var seedTex: texture_3d<f32>;
            @group(0) @binding(1) var seedSampler: sampler;
            @group(0) @binding(2) var volumeOut: texture_storage_3d<rgba8unorm, write>;
            @compute @workgroup_size(4, 4, 4)
            fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
              if (any(gid >= vec3<u32>(8u, 8u, 8u))) { return; }
              let sample = textureSampleLevel(seedTex, seedSampler,
                  vec3<f32>(0.5, 0.5, 0.5), 0.0);
              textureStore(volumeOut, vec3<i32>(gid), sample);
            }
            """
        let renderer = try fixture(device: device, definition: samplingDefinition,
            fill: samplingFill)
        let sourceName = try requireValue(renderer.graph.passes[0].inputs.first {
            $0.key == "seedTex"
        }?.value.stringValue)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 8
        descriptor.height = 8
        descriptor.depth = 8
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let seed = try requireValue(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 8 * 4)
        for z in 0..<8 { for y in 0..<8 { for x in 0..<8 {
            let offset = ((z * 8 + y) * 8 + x) * 4
            pixels[offset] = UInt8(x * 30)
            pixels[offset + 1] = UInt8(y * 28)
            pixels[offset + 2] = UInt8(z * 26)
            pixels[offset + 3] = 255
        } } }
        pixels.withUnsafeBytes { bytes in
            seed.replace(region: MTLRegionMake3D(0, 0, 0, 8, 8, 8),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: 8 * 4, bytesPerImage: 8 * 8 * 4)
        }
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let output = try renderer.encode(into: command,
            externalTextures: [sourceName: seed])
        let volume = try requireValue(output.graphTexture("node_0_volume"))
        let readback = try readVolume(volume, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let result = readback.contents().assumingMemoryBound(to: UInt8.self)
        // The fractional center lies halfway between voxels 3 and 4 on
        // every axis. Nearest sampling would yield (120, 112, 104).
        for offset in [0, 7 * 256 * 8 + 7 * 256 + 7 * 4] {
            for (channel, expected) in [105, 98, 91].enumerated() {
                expectLess(abs(Int(result[offset + channel]) - expected), 2)
            }
            expectEqual(result[offset + 3], 255)
        }
    }

    @Test func sourceStorageVolumeWritesEveryDepthSliceAndPersists() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try fixture(device: device)
        let queue = try requireValue(device.makeCommandQueue())
        var firstVolume: MTLTexture?
        for frame in 0..<8 {
            let command = try requireValue(queue.makeCommandBuffer())
            let output = try renderer.encode(frame: FrameState(time: 0.25,
                delta: 0, frameIndex: UInt64(frame)), into: command)
            let volume = try requireValue(output.graphTexture("node_0_volume"))
            if let firstVolume { expectTrue(volume === firstVolume) }
            else { firstVolume = volume }
            let readback = frame == 7 ? try readVolume(volume, into: command,
                device: device) : nil
            let presented: MTLBuffer?
            if frame == 7 {
                let buffer = try requireValue(device.makeBuffer(length: 256,
                    options: .storageModeShared))
                let blit = try requireValue(command.makeBlitCommandEncoder())
                blit.copy(from: output.texture, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 1, y: 1, z: 0),
                    sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                    to: buffer, destinationOffset: 0, destinationBytesPerRow: 256,
                    destinationBytesPerImage: 256)
                blit.endEncoding()
                presented = buffer
            } else { presented = nil }
            command.commit()
            command.waitUntilCompleted()
            expectEqual(command.status, .completed, "\(String(describing: command.error))")
            if let error = command.error { throw error }
            if let presented {
                let pixel = presented.contents().assumingMemoryBound(to: UInt16.self)
                expectLess(abs(Float(Float16(bitPattern: pixel[0])) - Float(1) / 7), 0.005)
                expectLess(abs(Float(Float16(bitPattern: pixel[1])) - Float(1) / 7), 0.005)
                expectLess(abs(Float(Float16(bitPattern: pixel[2]))), 0.005)
                expectLess(abs(Float(Float16(bitPattern: pixel[3])) - 1), 0.005)
            }
            if let readback {
                let bytes = Data(bytes: readback.contents(), count: 256 * 8 * 8)
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                // Apple WebGPU source volume readback, including zeroed row padding.
                expectEqual(digest, "7b90554d7ef967cde437e8e3c89e2ea219e880e100450e0aba47381e459378ab")
                let raw = [UInt8](bytes)
                for z in 0..<8 { for y in 0..<8 { for x in 0..<8 {
                    let offset = z * 256 * 8 + y * 256 + x * 4
                    expectLess(abs(Int(raw[offset]) - Int((Double(x) * 255 / 7).rounded())), 2)
                    expectLess(abs(Int(raw[offset + 1]) - Int((Double(y) * 255 / 7).rounded())), 2)
                    expectLess(abs(Int(raw[offset + 2]) - Int((Double(z) * 255 / 7).rounded())), 2)
                    expectEqual(raw[offset + 3], 255)
                } } }
            }
        }
    }

    @Test func explicitComputeEntryPointMatchesImplicitAcrossEveryVolumeSlice() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let explicitDefinition = definition.replacingOccurrences(of:
            #""type":"compute","program":"fill""#,
            with: #""type":"compute","program":"fill","entryPoint":"main""#)
        var captures: [Data] = []
        for variant in [definition, explicitDefinition] {
            let renderer = try fixture(device: device, definition: variant)
            let command = try requireValue(queue.makeCommandBuffer())
            let output = try renderer.encode(into: command)
            let volume = try requireValue(output.graphTexture("node_0_volume"))
            let readback = try readVolume(volume, into: command, device: device)
            command.commit()
            command.waitUntilCompleted()
            expectEqual(command.status, .completed, "\(String(describing: command.error))")
            if let error = command.error { throw error }
            let bytes = Data(bytes: readback.contents(), count: 256 * 8 * 8)
            captures.append(bytes)
            for z in 0..<8 { for y in 0..<8 { for x in 0..<8 {
                let offset = z * 256 * 8 + y * 256 + x * 4
                for (channel, position) in [x, y, z].enumerated() {
                    expectLess(abs(Int(bytes[offset + channel]) -
                        Int((Double(position) * 255 / 7).rounded())), 2)
                }
                expectEqual(bytes[offset + 3], 255)
            } } }
        }
        expectEqual(captures.count, 2)
        expectEqual(captures[0], captures[1])
        // Same tightly packed XYZ-ordered bytes captured by the upstream
        // test_webgpu_storage_volume_entrypoint.mjs real-device regression.
        for capture in captures {
            var packed = Data()
            for z in 0..<8 { for y in 0..<8 {
                let offset = z * 256 * 8 + y * 256
                packed.append(capture.subdata(in: offset..<(offset + 8 * 4)))
            } }
            let digest = SHA256.hash(data: packed).map { String(format: "%02x", $0) }.joined()
            expectEqual(digest, "1fa6c63e0cd32e71b5419746ba381058ca579d230dfbe0238fdc7008df3a5a9c")
        }
    }

    @Test func skippedStorageWriterKeepsVolumeAcrossCompletedFrames() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let conditional = definition.replacingOccurrences(of:
            #""workgroups":[2,2,2],"storageTextures""#,
            with: #""workgroups":[2,2,2],"conditions":{"runIf":[{"uniform":"frame","equals":0}]},"storageTextures""#)
        let renderer = try fixture(device: device, definition: conditional)
        let queue = try requireValue(device.makeCommandQueue())
        var digests: [String] = []
        for frame in 0..<2 {
            let command = try requireValue(queue.makeCommandBuffer())
            let output = try renderer.encode(frame: FrameState(time: 0.25,
                delta: 0, frameIndex: UInt64(frame)), into: command)
            let volume = try requireValue(output.graphTexture("node_0_volume"))
            let readback = try readVolume(volume, into: command, device: device)
            command.commit()
            command.waitUntilCompleted()
            expectEqual(command.status, .completed, "\(String(describing: command.error))")
            if let error = command.error { throw error }
            let bytes = Data(bytes: readback.contents(), count: 256 * 8 * 8)
            digests.append(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
        expectEqual(digests[0], digests[1])
    }

    @Test func reorderedVolumeSamplerDoesNotChangeSurfaceSampler() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        var registry = try EffectRegistry.bundled()
        let mixedDefinition = #"{"name":"Mixed Filter Probe","namespace":"user","func":"mixedFilterProbe","starter":true,"textures":{"surface":{"width":2,"height":1,"format":"rgba8unorm"}},"textures3d":{"volume":{"width":8,"height":8,"depth":8,"format":"rgba8unorm","filter":"linear"}},"passes":[{"program":"surface","outputs":{"fragColor":"surface"}},{"program":"show","inputs":{"surfaceTex":"surface","volTex":"volume"},"outputs":{"fragColor":"outputTex"}}]}"#
        let surfaceShader = """
            @fragment fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
              return vec4<f32>(select(0.0, 1.0, pixel.x < 1.0), 0.0, 0.0, 1.0);
            }
            """
        let mixedShader = """
            @group(0) @binding(0) var surfaceSampler: sampler;
            @group(0) @binding(1) var volSampler: sampler;
            @group(0) @binding(2) var surfaceTex: texture_2d<f32>;
            @group(0) @binding(3) var volTex: texture_3d<f32>;
            @fragment fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
              let volume = textureSample(volTex, volSampler, vec3<f32>(0.5, 0.5, 0.5));
              let surface = textureSample(surfaceTex, surfaceSampler, vec2<f32>(0.53125, 0.5));
              return vec4<f32>(volume.r, surface.r, 0.0, 1.0);
            }
            """
        try registry.registerPortable(definitionJSON: Data(mixedDefinition.utf8),
            orderedShaderSources: [("surface", surfaceShader), ("show", mixedShader)])
        let graph = try NoisemakerCompiler(registry: registry).compile(source:
            "search user\nmixedFilterProbe().write(o0)\nrender(o0)\n")
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 16, height: 16),
            defaultVertexWGSL: try requireValue(registry.defaultVertex.field("wgsl")?.stringValue),
            registry: registry)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 8
        descriptor.height = 8
        descriptor.depth = 8
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let volume = try requireValue(device.makeTexture(descriptor: descriptor))
        var voxels = [UInt8](repeating: 0, count: 8 * 8 * 8 * 4)
        for z in 0..<8 { for y in 0..<8 { for x in 0..<8 {
            let offset = ((z * 8 + y) * 8 + x) * 4
            voxels[offset] = UInt8(x * 31)
            voxels[offset + 3] = 255
        } } }
        voxels.withUnsafeBytes { bytes in
            volume.replace(region: MTLRegionMake3D(0, 0, 0, 8, 8, 8),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: 8 * 4, bytesPerImage: 8 * 8 * 4)
        }
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let output = try renderer.encode(into: command,
            externalTextures: ["node_0_volume": volume])
        let readback = try requireValue(device.makeBuffer(length: 256,
            options: .storageModeShared))
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: output.texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: readback, destinationOffset: 0, destinationBytesPerRow: 256,
            destinationBytesPerImage: 256)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let words = readback.contents().assumingMemoryBound(to: UInt16.self)
        let red = Float(Float16(bitPattern: words[0]))
        let green = Float(Float16(bitPattern: words[1]))
        expectLess(abs(red - Float(108) / 255), 0.005,
            "the volume's linear filter must survive reordered declarations")
        expectLess(abs(green), 0.005,
            "the internal 2D surface must keep nearest filtering")
    }
}
