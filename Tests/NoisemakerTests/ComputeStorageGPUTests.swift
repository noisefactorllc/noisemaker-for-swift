import CryptoKit
import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct ComputeStorageGPUTests {
    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private let definition = #"{"name":"Compute Buffer Retention Probe","namespace":"user","func":"computeBufferRetentionProbe","starter":true,"passes":[{"name":"compute","program":"compute","inputs":{},"outputs":{"fragColor":"outputTex"}}]}"#
    private let compute = """
        @group(0) @binding(0) var<storage, read_write> output_buffer: array<f32>;
        @group(0) @binding(1) var<uniform> frame: f32;
        @compute @workgroup_size(8,8,1)
        fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
          if (gid.x>=16u || gid.y>=8u) { return; }
          if (frame>0.5 && gid.x>=8u) { return; }
          let offset=(gid.y*16u+gid.x)*4u;
          let blue=frame>0.5;
          output_buffer[offset]=select(1.0,0.0,blue);
          output_buffer[offset+1u]=0.0;
          output_buffer[offset+2u]=select(0.0,1.0,blue);
          output_buffer[offset+3u]=1.0;
        }
        """

    private func makeRenderer(device: MTLDevice, size: RenderSize,
                              shader: String? = nil) throws -> NoisemakerRenderer {
        var registry = try EffectRegistry.bundled()
        try registry.registerPortable(definitionJSON: Data(definition.utf8),
            orderedShaderSources: [("compute", shader ?? compute)])
        let graph = try NoisemakerCompiler(registry: registry).compile(source:
            "search user\ncomputeBufferRetentionProbe().write(o0)\nrender(o0)\n")
        let vertex = registry.defaultVertex
        return try NoisemakerRenderer(device: device, graph: graph, size: size,
            defaultVertexWGSL: requireValue(vertex.field("wgsl")?.stringValue),
            vertexEntryPoint: requireValue(vertex.field("entryPoint")?.stringValue),
            registry: registry)
    }

    private func read(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> Data {
        guard texture.pixelFormat == .rgba16Float else {
            throw GraphDiagnostic.unsupported("compute probe output format")
        }
        let rowBytes = ((texture.width * 8 + 255) / 256) * 256
        let buffer = try requireValue(queue.device.makeBuffer(length: rowBytes * texture.height,
            options: .storageModeShared))
        let command = try requireValue(queue.makeCommandBuffer())
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed)
        if let error = command.error { throw error }
        var data = Data()
        for y in 0..<texture.height {
            data.append(buffer.contents().advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt8.self), count: texture.width * 8)
        }
        return data
    }

    private func read(_ buffer: MTLBuffer, queue: MTLCommandQueue) throws -> Data {
        let staging = try requireValue(queue.device.makeBuffer(length: buffer.length,
            options: .storageModeShared))
        let command = try requireValue(queue.makeCommandBuffer())
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: buffer, sourceOffset: 0, to: staging,
            destinationOffset: 0, size: buffer.length)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed)
        if let error = command.error { throw error }
        return Data(bytes: staging.contents(), count: buffer.length)
    }

    @Test func partialWritesPreserveStorageAcrossFrames() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let renderer = try makeRenderer(device: device, size: RenderSize(width: 16, height: 8))
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
        let storage = try requireValue(renderer.computeStorageBuffer(named: "output_buffer"))
        expectEqual(storage.length, 2048)
        expectEqual(sha(try read(storage, queue: queue)),
            "a031a76c6587d0b76c6873e32cf4dbf68498cc4c7d28c73f0201ee22bea8b728")
        let second = try encode(1)
        let retainedStorage = try requireValue(renderer.computeStorageBuffer(named: "output_buffer"))
        expectTrue(retainedStorage === storage)
        expectEqual(sha(try read(retainedStorage, queue: queue)),
            "2cb364b1c9906a10b7bf277577f7c24fa91a988604db40d5e356e74cdf2be26c")
        let output = try requireValue(second.graphTexture("node_0_out"))
        let expected = Data((0..<(16 * 8)).flatMap { pixel in
            pixel % 16 < 8 ? [UInt8(0), 0, 0, 0, 0, 60, 0, 60] :
                [0, 60, 0, 0, 0, 0, 0, 60]
        })
        expectEqual(try read(output, queue: queue), expected)
        withExtendedLifetime(first) {}
    }

    @Test func resetDiscardsStorageHistory() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let renderer = try makeRenderer(device: device, size: RenderSize(width: 16, height: 8))
        let firstCommand = try requireValue(queue.makeCommandBuffer())
        let first = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
            frameIndex: 0), into: firstCommand)
        firstCommand.commit()
        firstCommand.waitUntilCompleted()
        expectEqual(firstCommand.status, .completed)
        if let error = firstCommand.error { throw error }
        expectTrue(renderer.computeStorageBuffer(named: "output_buffer") != nil)
        try renderer.resetFeedback()
        expectTrue(renderer.computeStorageBuffer(named: "output_buffer") == nil)
        let secondCommand = try requireValue(queue.makeCommandBuffer())
        let second = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
            frameIndex: 1), into: secondCommand)
        secondCommand.commit()
        secondCommand.waitUntilCompleted()
        expectEqual(secondCommand.status, .completed)
        if let error = secondCommand.error { throw error }
        let output = try requireValue(second.graphTexture("node_0_out"))
        let expected = Data((0..<(16 * 8)).flatMap { pixel in
            pixel % 16 < 8 ? [UInt8(0), 0, 0, 0, 0, 60, 0, 60] :
                [0, 0, 0, 0, 0, 0, 0, 0]
        })
        expectEqual(try read(output, queue: queue), expected)
        withExtendedLifetime(first) {}
    }

    @Test func sameSizeReplacementTransfersStorageAndResizeStartsFresh() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let size = try RenderSize(width: 16, height: 8)
        let original = try makeRenderer(device: device, size: size)
        let firstCommand = try requireValue(queue.makeCommandBuffer())
        let first = try original.encode(frame: FrameState(time: 0.25, delta: 0,
            frameIndex: 0), into: firstCommand)
        firstCommand.commit()
        firstCommand.waitUntilCompleted()
        expectEqual(firstCommand.status, .completed)
        if let error = firstCommand.error { throw error }
        let buffer = try requireValue(original.computeStorageBuffer(named: "output_buffer"))
        let replacement = try makeRenderer(device: device, size: size)
        try replacement.adoptFeedback(from: original)
        expectTrue(replacement.computeStorageBuffer(named: "output_buffer") === buffer)
        expectTrue(original.computeStorageBuffer(named: "output_buffer") == nil)
        let secondCommand = try requireValue(queue.makeCommandBuffer())
        let second = try replacement.encode(frame: FrameState(time: 0.25, delta: 0,
            frameIndex: 1), into: secondCommand)
        secondCommand.commit()
        secondCommand.waitUntilCompleted()
        expectEqual(secondCommand.status, .completed)
        if let error = secondCommand.error { throw error }
        expectEqual(sha(try read(buffer, queue: queue)),
            "2cb364b1c9906a10b7bf277577f7c24fa91a988604db40d5e356e74cdf2be26c")
        let resized = try makeRenderer(device: device, size: RenderSize(width: 32, height: 8))
        try resized.adoptFeedback(from: replacement)
        expectTrue(resized.computeStorageBuffer(named: "output_buffer") == nil)
        withExtendedLifetime((first, second)) {}
    }

    @Test func abandonedInitializationIsRetried() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let renderer = try makeRenderer(device: device, size: RenderSize(width: 16, height: 8))
        weak var abandoned: MTLCommandBuffer?
        try autoreleasepool {
            let command = try requireValue(queue.makeCommandBuffer())
            abandoned = command
            _ = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
                frameIndex: 0), into: command)
        }
        expectNil(abandoned, "Renderer must not retain an uncommitted command")
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
            frameIndex: 1), into: command)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed)
        if let error = command.error { throw error }
        let output = try requireValue(lease.graphTexture("node_0_out"))
        let expected = Data((0..<(16 * 8)).flatMap { pixel in
            pixel % 16 < 8 ? [UInt8(0), 0, 0, 0, 0, 60, 0, 60] :
                [0, 0, 0, 0, 0, 0, 0, 0]
        })
        expectEqual(try read(output, queue: queue), expected)
    }

    @Test func oddDimensionsAlignStorageAndArrayLength() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let shader = compute.replacingOccurrences(of: "gid.x>=16u", with: "gid.x>=17u")
            .replacingOccurrences(of: "gid.y>=8u", with: "gid.y>=9u")
            .replacingOccurrences(of: "gid.y*16u", with: "gid.y*17u")
            .replacingOccurrences(of: "output_buffer[offset+3u]=1.0;",
                with: "output_buffer[offset+3u]=f32(arrayLength(&output_buffer))/640.0;")
        let renderer = try makeRenderer(device: device,
            size: RenderSize(width: 17, height: 9), shader: shader)
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
            frameIndex: 0), into: command)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed)
        if let error = command.error { throw error }
        let storage = try requireValue(renderer.computeStorageBuffer(named: "output_buffer"))
        expectEqual(storage.length, 2560)
        expectEqual(storage.length / MemoryLayout<Float>.size, 640)
        let bytes = try read(storage, queue: queue)
        expectTrue(bytes.dropFirst(17 * 9 * 16).allSatisfy { $0 == 0 })
        let output = try requireValue(lease.graphTexture("node_0_out"))
        let expected = Data((0..<(17 * 9)).flatMap { _ in
            [UInt8(0), 60, 0, 0, 0, 0, 0, 60]
        })
        expectEqual(try read(output, queue: queue), expected)
    }
}
