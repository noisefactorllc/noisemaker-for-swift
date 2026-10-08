import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct FeedbackGPUTests {
    private var reference: URL {
        ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"].map(URL.init(fileURLWithPath:)) ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/reference")
    }

    private func renderer(_ device: MTLDevice) throws -> NoisemakerRenderer {
        let graph = try RenderGraph(exportedCaseData: Data(contentsOf:
            reference.appendingPathComponent("cases/repeatFeedback.json")))
        let vertex = try requireValue(JSONSerialization.jsonObject(with: Data(contentsOf:
            reference.appendingPathComponent("default-vertex.json"))) as? [String: Any])
        return try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 257, height: 129),
            defaultVertexWGSL: try requireValue(vertex["wgsl"] as? String),
            vertexEntryPoint: try requireValue(vertex["entryPoint"] as? String))
    }

    private func readback(_ texture: MTLTexture, queue: MTLCommandQueue,
                          device: MTLDevice) throws -> Data {
        let rowBytes = ((texture.width * 8 + 255) / 256) * 256
        let buffer = try requireValue(device.makeBuffer(length: rowBytes * texture.height,
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
        return Data(bytes: buffer.contents(), count: rowBytes * texture.height)
    }

    @Test func testSourceRepeatAdvancesPersistentPixelsAndPreservesOutputLease() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal required")
        let renderer = try renderer(device)
        let queue = try requireValue(device.makeCommandQueue())
        let firstCommand = try requireValue(queue.makeCommandBuffer())
        let first = try renderer.encode(frame: FrameState(time: 0.25, delta: 0, frameIndex: 0),
            into: firstCommand)
        expectTrue(first.graphTexture("global_rd_state_chain_0") != nil)
        firstCommand.commit()
        firstCommand.waitUntilCompleted()
        expectEqual(firstCommand.status, .completed)
        let firstPixels = try readback(first.texture, queue: queue, device: device)
        var last = first
        for index in 1..<8 {
            let command = try requireValue(queue.makeCommandBuffer())
            last = try renderer.encode(frame: FrameState(time: 0.25, delta: 0,
                frameIndex: UInt64(index)), into: command)
            command.commit()
            command.waitUntilCompleted()
            expectEqual(command.status, .completed)
            if let error = command.error { throw error }
        }
        let lastPixels = try readback(last.texture, queue: queue, device: device)
        expectFalse(first.texture === last.texture)
        let differingBytes = zip(firstPixels, lastPixels).filter { $0 != $1 }.count
        expectTrue(differingBytes > 1_000, "eight frames must evolve actual feedback pixels")
        expectEqual(try readback(first.texture, queue: queue, device: device), firstPixels,
            "retained first-frame output must not be overwritten by feedback reuse")
        try renderer.resetFeedback()
        let resetCommand = try requireValue(queue.makeCommandBuffer())
        let reset = try renderer.encode(frame: FrameState(time: 0.25, delta: 0, frameIndex: 0),
            into: resetCommand)
        resetCommand.commit()
        resetCommand.waitUntilCompleted()
        expectEqual(resetCommand.status, .completed)
        expectEqual(try readback(reset.texture, queue: queue, device: device), firstPixels,
            "reset must restore the zero-initialized first-frame state")
    }

    @Test func testFeedbackRefusesInFlightFrameAndRecoversAfterCompletion() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal required")
        let renderer = try renderer(device)
        let queue = try requireValue(device.makeCommandQueue())
        let event = try requireValue(device.makeSharedEvent())
        let firstCommand = try requireValue(queue.makeCommandBuffer())
        firstCommand.encodeWaitForEvent(event, value: 1)
        let first = try renderer.encode(into: firstCommand)
        firstCommand.commit()
        defer { event.signaledValue = 1 }
        expectThrows(try renderer.encode(into: requireValue(queue.makeCommandBuffer())))
        expectThrows(try renderer.resetFeedback())
        event.signaledValue = 1
        firstCommand.waitUntilCompleted()
        expectEqual(firstCommand.status, .completed)
        let next = try requireValue(queue.makeCommandBuffer())
        let second = try renderer.encode(into: next)
        expectFalse(first.texture === second.texture)
        next.commit()
        next.waitUntilCompleted()
        expectEqual(next.status, .completed)
    }

    @Test func testAbandonedBorrowedFeedbackFrameCanBeReencoded() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal required")
        let renderer = try renderer(device)
        let queue = try requireValue(device.makeCommandQueue())
        weak var abandoned: MTLCommandBuffer?
        try autoreleasepool {
            let command = try requireValue(queue.makeCommandBuffer())
            abandoned = command
            _ = try renderer.encode(into: command)
        }
        expectNil(abandoned)
        let resumed = try requireValue(queue.makeCommandBuffer())
        _ = try renderer.encode(into: resumed)
        resumed.commit()
        resumed.waitUntilCompleted()
        expectEqual(resumed.status, .completed)
    }

    @Test func testOrdinarySourceFeedbackTextureSurvivesFramesAndResets() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal required")
        let compiler = try NoisemakerCompiler()
        let source = """
            search synth, filter
            noise(seed: 1, scaleX: 50, scaleY: 50).feedback(mix: 50, scaleAmt: 110).write(o0)
            render(o0)
            """
        let graph = try compiler.compile(source: source)
        let vertex = compiler.registry.defaultVertex
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 64, height: 48),
            defaultVertexWGSL: try requireValue(vertex.field("wgsl")?.stringValue),
            vertexEntryPoint: try requireValue(vertex.field("entryPoint")?.stringValue),
            registry: compiler.registry)
        let queue = try requireValue(device.makeCommandQueue())
        let firstCommand = try requireValue(queue.makeCommandBuffer())
        let first = try renderer.encode(into: firstCommand)
        let ordinary = try requireValue(first.graphTexture("node_1__selfTex"))
        firstCommand.commit()
        firstCommand.waitUntilCompleted()
        expectEqual(firstCommand.status, .completed, "\(String(describing: firstCommand.error))")
        if let error = firstCommand.error { throw error }
        let firstPixels = try readback(first.texture, queue: queue, device: device)
        let nextCommand = try requireValue(queue.makeCommandBuffer())
        let next = try renderer.encode(into: nextCommand)
        expectTrue(next.graphTexture("node_1__selfTex") === ordinary)
        expectFalse(next.texture === first.texture)
        nextCommand.commit()
        nextCommand.waitUntilCompleted()
        expectEqual(nextCommand.status, .completed, "\(String(describing: nextCommand.error))")
        if let error = nextCommand.error { throw error }
        let nextPixels = try readback(next.texture, queue: queue, device: device)
        expectTrue(zip(firstPixels, nextPixels).contains { $0 != $1 },
            "feedback must observe prior-frame ordinary texture pixels")
        try renderer.resetFeedback()
        let resetCommand = try requireValue(queue.makeCommandBuffer())
        let reset = try renderer.encode(into: resetCommand)
        resetCommand.commit()
        resetCommand.waitUntilCompleted()
        expectEqual(resetCommand.status, .completed)
        expectEqual(try readback(reset.texture, queue: queue, device: device), firstPixels)
    }
}
