import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct FeedbackTransferGPUTests {
    private func make(_ device: MTLDevice, size: RenderSize? = nil) throws -> NoisemakerRenderer {
        let graph = try NoisemakerCompiler().compile(source:
            "search synth, filter\nnoise(seed: 1, scaleX: 50, scaleY: 50).feedback(mix: 50, scaleAmt: 110).write(o0)\nrender(o0)\n")
        return try NoisemakerRenderer(device: device, graph: graph,
            size: size ?? RenderSize(width: 65, height: 33))
    }
    private func frame(_ renderer: NoisemakerRenderer, _ queue: MTLCommandQueue) throws -> OutputLease {
        let command = try requireValue(queue.makeCommandBuffer())
        let output = try renderer.encode(into: command)
        command.commit(); command.waitUntilCompleted()
        expectEqual(command.status, .completed)
        if let error = command.error { throw error }
        return output
    }
    private func pixels(_ texture: MTLTexture, _ queue: MTLCommandQueue) throws -> Data {
        let row = ((texture.width * 8 + 255) / 256) * 256
        let bytes = try requireValue(queue.device.makeBuffer(length: row * texture.height, options: .storageModeShared))
        let command = try requireValue(queue.makeCommandBuffer())
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0,y: 0,z: 0),
            sourceSize: MTLSize(width: texture.width,height: texture.height,depth: 1), to: bytes,
            destinationOffset: 0,destinationBytesPerRow: row,destinationBytesPerImage: row * texture.height)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        var data = Data()
        for y in 0..<texture.height { data.append(bytes.contents().advanced(by: y * row).assumingMemoryBound(to: UInt8.self), count: texture.width * 8) }
        return data
    }
    @Test func completedStateTransferContinuesPixelsAndRetiresSource() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let queue = try requireValue(device.makeCommandQueue())
        let old = try make(device), control = try make(device), prepared = try make(device)
        var before: OutputLease!
        for _ in 0..<3 { before = try frame(old, queue); _ = try frame(control, queue) }
        let retained = try pixels(before.texture, queue)
        try prepared.adoptFeedback(from: old)
        expectThrows(try old.encode(into: requireValue(queue.makeCommandBuffer())))
        expectThrows(try old.resetFeedback())
        let next = try frame(prepared, queue), expected = try frame(control, queue)
        expectTrue(next.graphTexture("node_1__selfTex") === before.graphTexture("node_1__selfTex"))
        expectEqual(try pixels(next.texture, queue), try pixels(expected.texture, queue))
        expectEqual(try pixels(before.texture, queue), retained)
    }
    @Test func pendingTransferFailureLeavesBothRenderersUsable() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let queue = try requireValue(device.makeCommandQueue())
        let old = try make(device), prepared = try make(device)
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try old.encode(into: command)
        expectThrows(try prepared.adoptFeedback(from: old))
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        _ = try frame(prepared, queue)
        try prepared.adoptFeedback(from: old)
        let next = try frame(prepared, queue)
        expectTrue(next.graphTexture("node_1__selfTex") === lease.graphTexture("node_1__selfTex"))
    }
    @Test func dimensionChangeRecreatesNonpersistentFeedback() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let queue = try requireValue(device.makeCommandQueue())
        let old = try make(device)
        let size = try RenderSize(width: 33, height: 17)
        let prepared = try make(device, size: size), fresh = try make(device, size: size)
        for _ in 0..<3 { _ = try frame(old, queue) }
        try prepared.adoptFeedback(from: old)
        let actual = try frame(prepared, queue), expected = try frame(fresh, queue)
        expectEqual(try pixels(actual.texture, queue), try pixels(expected.texture, queue))
    }

}
