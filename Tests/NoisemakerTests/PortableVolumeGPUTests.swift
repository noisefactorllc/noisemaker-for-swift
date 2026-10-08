import Foundation
import Metal
import Testing
@testable import Noisemaker
@testable import NoisemakerMetalKit

@Suite(.serialized)
struct PortableVolumeGPUTests {
    private let definition = #"{"name":"Sampled 3D Probe","namespace":"user","func":"sampled3dProbe","starter":true,"textures3d":{"volume":{"width":8,"height":8,"depth":8,"format":"rgba8unorm","filter":"nearest"}},"passes":[{"name":"show","program":"show","inputs":{"volTex":"volume"},"outputs":{"fragColor":"outputTex"}}]}"#
    private let shader = """
        @group(0) @binding(0) var volTex: texture_3d<f32>;
        @fragment
        fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
          let x = i32(pixel.x) % 8;
          let y = i32(pixel.y) % 8;
          let z = (i32(pixel.x) / 32 + i32(pixel.y) / 32) % 8;
          return textureLoad(volTex, vec3<i32>(x, y, z), 0);
        }
        """
    private let source = "search user\nsampled3dProbe().write(o0)\nrender(o0)\n"

    private func fixture(device: MTLDevice, definition: String? = nil,
                         shader: String? = nil, source: String? = nil,
                         size: (Int, Int) = (256, 256)) throws -> NoisemakerRenderer {
        var registry = try EffectRegistry.bundled()
        try registry.registerPortable(definitionJSON: Data((definition ?? self.definition).utf8),
                                      orderedShaderSources: [("show", shader ?? self.shader)])
        let graph = try NoisemakerCompiler(registry: registry).compile(source: source ?? self.source)
        let vertex = registry.defaultVertex
        return try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: size.0, height: size.1),
            defaultVertexWGSL: try requireValue(vertex.field("wgsl")?.stringValue),
            vertexEntryPoint: try requireValue(vertex.field("entryPoint")?.stringValue),
            registry: registry)
    }

    @Test func sourceLinearVolumeFixtureVariesAcrossXYZ() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let definition = try String(contentsOf: root.appendingPathComponent(
            "parity/sampled3d-linear.portable.json"), encoding: .utf8)
        let shader = try String(contentsOf: root.appendingPathComponent(
            "parity/sampled3d-linear.show.wgsl"), encoding: .utf8)
        let source = try String(contentsOf: root.appendingPathComponent(
            "parity/sampled3d-linear.dsl"), encoding: .utf8)
        let volumeBytes = try Data(contentsOf: root.appendingPathComponent(
            "parity/inputs/sampled3d-v1.rgba8"))
        expectEqual(volumeBytes.count, 8 * 8 * 8 * 4)
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try fixture(device: device, definition: definition,
            shader: shader, source: source, size: (257, 129))
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 8
        descriptor.height = 8
        descriptor.depth = 8
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let volume = try requireValue(device.makeTexture(descriptor: descriptor))
        volumeBytes.withUnsafeBytes { bytes in
            volume.replace(region: MTLRegionMake3D(0, 0, 0, 8, 8, 8),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: 8 * 4, bytesPerImage: 8 * 8 * 4)
        }
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let output = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
            frameIndex: 7), into: command,
            externalTextures: ["node_0_volume": volume])
        let presentedDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 257, height: 129, mipmapped: false)
        presentedDescriptor.storageMode = .shared
        presentedDescriptor.usage = .renderTarget
        let presented = try requireValue(device.makeTexture(descriptor: presentedDescriptor))
        try TexturePresenter(device: device).encode(source: output.texture,
            target: presented, into: command)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        var pixels = [UInt8](repeating: 0, count: 257 * 129 * 4)
        presented.getBytes(&pixels, bytesPerRow: 257 * 4,
            from: MTLRegionMake2D(0, 0, 257, 129), mipmapLevel: 0)
        // The same sidecars captured on locked WebGPU: varying x, y and z
        // across the surface distinguish fractional sampling from nearest.
        let expected: [(Int, Int, [UInt8])] = [
            (3, 3, [89, 158, 0, 255]),
            (7, 3, [213, 158, 0, 255]),
            (3, 7, [89, 34, 0, 255]),
            (35, 3, [89, 158, 29, 255]),
            (99, 11, [89, 158, 91, 255])
        ]
        for (x, y, rgba) in expected {
            for channel in 0..<4 {
                let stored = channel == 0 ? 2 : (channel == 2 ? 0 : channel)
                let actual = pixels[(y * 257 + x) * 4 + stored]
                expectLess(abs(Int(actual) - Int(rgba[channel])), 3,
                    "source linear pixel (\(x),\(y)) channel \(channel)")
            }
        }
    }

    @Test func sourceBackedHostVolumeSamplesDistinctDepthSlices() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try fixture(device: device)

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 8
        descriptor.height = 8
        descriptor.depth = 8
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let volume = try requireValue(device.makeTexture(descriptor: descriptor))
        var voxels = [UInt8](repeating: 0, count: 8 * 8 * 8 * 4)
        for z in 0..<8 { for y in 0..<8 { for x in 0..<8 {
            let index = ((z * 8 + y) * 8 + x) * 4
            voxels[index] = UInt8(x * 31)
            voxels[index + 1] = UInt8(y * 31)
            voxels[index + 2] = UInt8(z * 31)
            voxels[index + 3] = 255
        } } }
        voxels.withUnsafeBytes { bytes in
            volume.replace(region: MTLRegionMake3D(0, 0, 0, 8, 8, 8), mipmapLevel: 0, slice: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: 8 * 4,
                bytesPerImage: 8 * 8 * 4)
        }

        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let output = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
            frameIndex: 7), into: command, externalTextures: ["node_0_volume": volume])
        expectEqual(output.texture.width, 256)
        expectEqual(output.texture.height, 256)
        let presentedDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 256, height: 256, mipmapped: false)
        presentedDescriptor.storageMode = .shared
        presentedDescriptor.usage = .renderTarget
        let presented = try requireValue(device.makeTexture(descriptor: presentedDescriptor))
        try TexturePresenter(device: device).encode(source: output.texture,
            target: presented, into: command)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }

        // Pinned WebGPU browser source: sampled3d-probe.png, 512 opaque colors.
        let expected: [(Int, Int, [UInt8])] = [
            (1, 1, [31, 186, 217, 255]),
            (33, 1, [31, 186, 0, 255]),
            (1, 33, [31, 186, 186, 255]),
            (254, 254, [186, 31, 217, 255]),
            (17, 200, [31, 217, 31, 255]),
            (200, 17, [0, 186, 155, 255])
        ]
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        presented.getBytes(&bytes, bytesPerRow: 256 * 4,
            from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
        for (x, y, rgba) in expected {
            for channel in 0..<4 {
                let storedChannel = channel == 0 ? 2 : (channel == 2 ? 0 : channel)
                let value = bytes[(y * 256 + x) * 4 + storedChannel]
                expectLess(abs(Int(value) - Int(rgba[channel])), 3,
                    "source pixel (\(x),\(y)) channel \(channel)")
            }
        }
    }

    @Test func sourceOwnedVolumeStartsTransparentAndWrongHostDepthRefuses() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try fixture(device: device)
        let queue = try requireValue(device.makeCommandQueue())
        let invalidDescriptor = MTLTextureDescriptor()
        invalidDescriptor.textureType = .type3D
        invalidDescriptor.pixelFormat = .rgba8Unorm
        invalidDescriptor.width = 8
        invalidDescriptor.height = 8
        invalidDescriptor.depth = 7
        invalidDescriptor.storageMode = .shared
        invalidDescriptor.usage = .shaderRead
        let invalidVolume = try requireValue(device.makeTexture(descriptor: invalidDescriptor))
        let refused = try requireValue(queue.makeCommandBuffer())
        expectThrows(try renderer.encode(into: refused,
            externalTextures: ["node_0_volume": invalidVolume]),
            "host volume depth must match the graph before any GPU work")
        expectEqual(refused.status, .notEnqueued)

        let command = try requireValue(queue.makeCommandBuffer())
        let output = try renderer.encode(into: command)
        let buffer = try requireValue(device.makeBuffer(length: 256 * 256 * 8,
            options: .storageModeShared))
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: output.texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 256, height: 256, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: 256 * 8,
            destinationBytesPerImage: 256 * 256 * 8)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let words = buffer.contents().assumingMemoryBound(to: UInt16.self)
        for channel in 0..<4 { expectEqual(words[channel], UInt16(0)) }
    }

    @Test func hostVolumeRemainsSampleableAcrossFramesWhenSuppliedEachEncode() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try fixture(device: device)
        let queue = try requireValue(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 8
        descriptor.height = 8
        descriptor.depth = 8
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let volume = try requireValue(device.makeTexture(descriptor: descriptor))
        var red = [UInt8](repeating: 0, count: 8 * 8 * 8 * 4)
        for offset in stride(from: 0, to: red.count, by: 4) {
            red[offset] = 255
            red[offset + 3] = 255
        }
        red.withUnsafeBytes { bytes in
            volume.replace(region: MTLRegionMake3D(0, 0, 0, 8, 8, 8), mipmapLevel: 0,
                slice: 0, withBytes: bytes.baseAddress!, bytesPerRow: 8 * 4,
                bytesPerImage: 8 * 8 * 4)
        }
        let first = try requireValue(queue.makeCommandBuffer())
        _ = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
            frameIndex: 0), into: first, externalTextures: ["node_0_volume": volume])
        first.commit()
        first.waitUntilCompleted()
        expectEqual(first.status, .completed, "\(String(describing: first.error))")

        let second = try requireValue(queue.makeCommandBuffer())
        let output = try renderer.encode(frame: FrameState(time: 0.5, delta: 0.25,
            frameIndex: 1), into: second,
            externalTextures: ["node_0_volume": volume])
        let buffer = try requireValue(device.makeBuffer(length: 256 * 256 * 8,
            options: .storageModeShared))
        let blit = try requireValue(second.makeBlitCommandEncoder())
        blit.copy(from: output.texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 256, height: 256, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: 256 * 8,
            destinationBytesPerImage: 256 * 256 * 8)
        blit.endEncoding()
        second.commit()
        second.waitUntilCompleted()
        expectEqual(second.status, .completed, "\(String(describing: second.error))")
        if let error = second.error { throw error }
        let words = buffer.contents().assumingMemoryBound(to: UInt16.self)
        expectEqual(Float(Float16(bitPattern: words[0])), Float(1), accuracy: 0.001)
        expectEqual(Float(Float16(bitPattern: words[3])), Float(1), accuracy: 0.001)
    }

    @Test func authored3DFilterMatchesWebGL2AndPatchedWebGPU() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let sampleShader = """
            @group(0) @binding(0) var volTex: texture_3d<f32>;
            @group(0) @binding(1) var volSampler: sampler;
            @fragment
            fn main(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
              return textureSample(volTex, volSampler, vec3<f32>(0.5, 0.5, 0.5));
            }
            """
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
            voxels[offset + 1] = UInt8(y * 31)
            voxels[offset + 2] = UInt8(z * 31)
            voxels[offset + 3] = 255
        } } }
        voxels.withUnsafeBytes { bytes in
            volume.replace(region: MTLRegionMake3D(0, 0, 0, 8, 8, 8), mipmapLevel: 0,
                slice: 0, withBytes: bytes.baseAddress!, bytesPerRow: 8 * 4,
                bytesPerImage: 8 * 8 * 4)
        }

        for (filter, sourcePixel) in [("nearest", UInt8(124)), ("linear", UInt8(108))] {
            let authored = definition.replacingOccurrences(of: "\"filter\":\"nearest\"",
                with: "\"filter\":\"\(filter)\"")
            let renderer = try fixture(device: device, definition: authored, shader: sampleShader)
            let command = try requireValue(queue.makeCommandBuffer())
            let output = try renderer.encode(into: command,
                externalTextures: ["node_0_volume": volume])
            let presentedDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 256, height: 256, mipmapped: false)
            presentedDescriptor.storageMode = .shared
            presentedDescriptor.usage = .renderTarget
            let presented = try requireValue(device.makeTexture(descriptor: presentedDescriptor))
            try TexturePresenter(device: device).encode(source: output.texture,
                target: presented, into: command)
            command.commit()
            command.waitUntilCompleted()
            expectEqual(command.status, .completed, "\(String(describing: command.error))")
            if let error = command.error { throw error }
            var pixel = [UInt8](repeating: 0, count: 4)
            presented.getBytes(&pixel, bytesPerRow: 4,
                from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            expectEqual(pixel, [sourcePixel, sourcePixel, sourcePixel, 255],
                "\(filter) 3D sampler against WebGL2 and diagnostic patched WebGPU")
        }
    }
}
