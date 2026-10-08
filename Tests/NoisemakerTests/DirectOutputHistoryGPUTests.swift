import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct DirectOutputHistoryGPUTests {
    private func replacing(_ entries: [[Any]], key: String, with value: Any) -> [[Any]] {
        entries.map { entry in
            entry.first as? String == key ? [key, value] : entry
        }
    }

    private func conditionalDirectOutputGraph() throws -> RenderGraph {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent(".build/reference/cases/solid.json")
        var caseFile = try requireValue(JSONSerialization.jsonObject(with:
            Data(contentsOf: fixture)) as? [String: Any])
        var stages = try requireValue(caseFile["stages"] as? [String: Any])
        var graph = try requireValue(stages["graph"] as? [String: Any])
        var graphEntries = try requireValue(graph["entries"] as? [[Any]])
        let passes = try requireValue(graphEntries.first { $0.first as? String == "passes" }?[1] as? [Any])
        var pass = try requireValue(passes.first as? [String: Any])
        var passEntries = try requireValue(pass["entries"] as? [[Any]])
        let output: [String: Any] = ["$type": "object", "entries": [["color", "global_o0"]]]
        let predicate: [String: Any] = ["$type": "object", "entries": [["uniform", "frame"], ["equals", 0]]]
        let conditions: [String: Any] = ["$type": "object",
            "entries": [["runIf", [predicate]], ["skipIf", []]]]
        passEntries = replacing(passEntries, key: "outputs", with: output)
        passEntries = replacing(passEntries, key: "conditions", with: conditions)
        pass["entries"] = passEntries
        graphEntries = replacing(graphEntries, key: "passes", with: [pass])
        let emptyMap: [String: Any] = ["$type": "map", "entries": []]
        graphEntries = replacing(graphEntries, key: "allocations", with: emptyMap)
        graphEntries = replacing(graphEntries, key: "textures", with: emptyMap)
        graph["entries"] = graphEntries
        stages["graph"] = graph
        caseFile["stages"] = stages
        return try RenderGraph(exportedCaseData:
            JSONSerialization.data(withJSONObject: caseFile))
    }

    private func firstPixel(_ texture: MTLTexture, device: MTLDevice,
                            queue: MTLCommandQueue) throws -> [UInt16] {
        let bytesPerRow = ((texture.width * 8 + 255) / 256) * 256
        let buffer = try requireValue(device.makeBuffer(length: bytesPerRow * texture.height,
            options: .storageModeShared))
        let command = try requireValue(queue.makeCommandBuffer())
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed)
        if let error = command.error { throw error }
        return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt16.self), count: 4))
    }

    @Test func skippedDirectDisplayWriterPreservesFrameZeroOnFrameOne() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal required")
        let graph = try conditionalDirectOutputGraph()
        let vertex = try requireValue(EffectRegistry.bundled().defaultVertex.field("wgsl")?.stringValue)
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 17, height: 9), defaultVertexWGSL: vertex)
        let queue = try requireValue(device.makeCommandQueue())
        var colors: [[UInt16]] = []
        var backing: [MTLTexture] = []
        for index in 0..<6 {
            let submitted = try renderer.render(frame: FrameState(time: Double(index) / 10,
                delta: index == 0 ? 0 : 0.1, frameIndex: UInt64(index)))
            submitted.commandBuffer.waitUntilCompleted()
            expectEqual(submitted.commandBuffer.status, .completed)
            colors.append(try firstPixel(submitted.output.texture, device: device, queue: queue))
            backing.append(try requireValue(submitted.output.graphTexture("global_o0")))
        }
        let firstColor = colors[0]
        expectFalse(firstColor.allSatisfy { $0 == 0 })
        // Executing the locked Pipeline.render/shouldSkipPass/swapBuffers on the
        // same one-writer graph yields backing IDs B,B,A,B,A,B for frames 0...5.
        // Only B was written on frame 0; A retains its initial zero contents.
        let expectedColors = [firstColor, firstColor, [0, 0, 0, 0],
                              firstColor, [0, 0, 0, 0], firstColor]
        let expectedBacking = [0, 0, 2, 0, 2, 0]
        for index in 0..<6 {
            expectEqual(colors[index], expectedColors[index],
                "locked Pipeline.render display ping-pong at frame \(index)")
            expectTrue(backing[index] === backing[expectedBacking[index]],
                "source display backing identity at frame \(index)")
        }
        expectFalse(backing[0] === backing[2])
    }

    @Test func unconditionalBlitOutputKeepsMultiplePendingFrames() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal required")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let graph = try RenderGraph(exportedCaseData: Data(contentsOf:
            root.appendingPathComponent(".build/reference/cases/solid.json")))
        let vertex = try requireValue(EffectRegistry.bundled().defaultVertex.field("wgsl")?.stringValue)
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 17, height: 9), defaultVertexWGSL: vertex)
        let queue = try requireValue(device.makeCommandQueue())
        let event = try requireValue(device.makeSharedEvent())
        defer { event.signaledValue = 1 }
        let firstCommand = try requireValue(queue.makeCommandBuffer())
        let first = try renderer.encode(into: firstCommand)
        firstCommand.encodeWaitForEvent(event, value: 1)
        firstCommand.commit()
        let secondCommand = try requireValue(queue.makeCommandBuffer())
        let second = try renderer.encode(frame: FrameState(time: 0.1, delta: 0.1,
            frameIndex: 1), into: secondCommand)
        secondCommand.commit()
        expectFalse(first.texture === second.texture)
        event.signaledValue = 1
        firstCommand.waitUntilCompleted()
        secondCommand.waitUntilCompleted()
        expectEqual(firstCommand.status, .completed)
        expectEqual(secondCommand.status, .completed)
    }
}
