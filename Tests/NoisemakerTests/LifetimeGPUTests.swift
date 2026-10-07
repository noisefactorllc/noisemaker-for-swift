import Foundation
import Metal
import XCTest
@testable import Noisemaker

final class LifetimeGPUTests: XCTestCase {
    private func renderer(_ device: MTLDevice, corruptFinalUniform: Bool = false) throws -> NoisemakerRenderer {
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"].map(URL.init(fileURLWithPath:)) ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/reference")
        var caseData = try Data(contentsOf: reference.appendingPathComponent("cases/marker.json"))
        if corruptFinalUniform {
            // Keep the real first pass and make the final pass fail only while
            // packing its uniform, after the first encoder has recorded work.
            func field(_ object: [String: Any], _ name: String) -> Any {
                (object["entries"] as! [[Any]]).first { ($0[0] as? String) == name }![1]
            }
            func replacing(_ object: [String: Any], _ name: String, _ value: Any) -> [String: Any] {
                var result = object
                var entries = object["entries"] as! [[Any]]
                if let index = entries.firstIndex(where: { ($0[0] as? String) == name }) { entries[index][1] = value }
                else { entries.append([name, value]) }
                result["entries"] = entries
                return result
            }
            var exported = try XCTUnwrap(JSONSerialization.jsonObject(with: caseData) as? [String: Any])
            var stages = exported["stages"] as! [String: Any]
            var graph = stages["graph"] as! [String: Any]
            var programs = field(graph, "programs") as! [String: Any]
            var blit = field(programs, "blit") as! [String: Any]
            let wgsl = (field(blit, "wgsl") as! String)
                .replacingOccurrences(of: "return textureSample(src, srcSampler, uv);", with: "return textureSample(src, srcSampler, uv) * failValue;") +
                "\n@group(0) @binding(2) var<uniform> failValue: vec4<f32>;\n"
            blit = replacing(blit, "wgsl", wgsl)
            programs = replacing(programs, "blit", blit)
            graph = replacing(graph, "programs", programs)
            var passes = field(graph, "passes") as! [[String: Any]]
            passes[passes.count - 1] = replacing(passes.last!, "uniforms",
                ["$type": "object", "entries": [["failValue", "invalid-number"]]])
            graph = replacing(graph, "passes", passes)
            stages["graph"] = graph
            exported["stages"] = stages
            var shaderExports = exported["programs"] as! [String: [String: Any]]
            shaderExports["blit"]!["resolvedWGSL"] = wgsl
            shaderExports["blit"]!["originalWGSL"] = wgsl
            exported["programs"] = shaderExports
            caseData = try JSONSerialization.data(withJSONObject: exported)
        }
        let graph = try RenderGraph(exportedCaseData: caseData)
        let vertex = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reference.appendingPathComponent("default-vertex.json"))) as? [String: Any])
        return try NoisemakerRenderer(device: device, graph: graph, size: RenderSize(width: 257, height: 129),
            defaultVertexWGSL: try XCTUnwrap(vertex["wgsl"] as? String))
    }

    func testUnretainedCommandSurvivesRendererAndLeaseRelease() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let event = try XCTUnwrap(device.makeSharedEvent())
        let command = try XCTUnwrap(queue.makeCommandBufferWithUnretainedReferences())
        command.encodeWaitForEvent(event, value: 1)
        let stride = ((257 * 8 + 255) / 256) * 256
        let staging = try XCTUnwrap(device.makeBuffer(length: stride * 129, options: .storageModeShared))
        try autoreleasepool {
            let renderer = try renderer(device)
            let lease = try renderer.encode(into: command)
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: lease.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0,y: 0,z: 0),
                sourceSize: MTLSize(width: 257,height: 129,depth: 1), to: staging, destinationOffset: 0,
                destinationBytesPerRow: stride, destinationBytesPerImage: stride * 129)
            blit.endEncoding()
            command.commit()
        }
        event.signaledValue = 1
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        let words = staging.contents().assumingMemoryBound(to: UInt16.self)
        XCTAssertEqual(Float(Float16(bitPattern: words[8 * stride / 2 + 8 * 4])), 1)
        XCTAssertEqual(Float(Float16(bitPattern: words[120 * stride / 2 + 8 * 4 + 2])), 1)
    }

    func testPartialEncodingFailureRetainsUnretainedCommandResources() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let event = try XCTUnwrap(device.makeSharedEvent())
        let command = try XCTUnwrap(queue.makeCommandBufferWithUnretainedReferences())
        command.encodeWaitForEvent(event, value: 1)
        try autoreleasepool {
            let renderer = try renderer(device, corruptFinalUniform: true)
            XCTAssertThrowsError(try renderer.encode(into: command)) { error in
                XCTAssertTrue(String(describing: error).contains("failValue"))
            }
            command.commit()
        }
        event.signaledValue = 1
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
    }

    func testRejectsUncommittedFramesAndOtherQueues() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try renderer(device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let first = try XCTUnwrap(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: first)
        XCTAssertThrowsError(try renderer.encode(into: first))
        XCTAssertThrowsError(try renderer.encode(into: XCTUnwrap(queue.makeCommandBuffer())))
        first.commit()
        let otherQueue = try XCTUnwrap(device.makeCommandQueue())
        XCTAssertThrowsError(try renderer.encode(into: XCTUnwrap(otherQueue.makeCommandBuffer())))
        first.waitUntilCompleted()
        XCTAssertEqual(first.status, .completed)
        withExtendedLifetime(lease) {}
    }

    func testAbandonedBorrowedCommandDoesNotBlockFutureFrames() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try renderer(device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        weak var abandoned: MTLCommandBuffer?
        try autoreleasepool {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            abandoned = command
            _ = try renderer.encode(into: command)
        }
        XCTAssertNil(abandoned, "Renderer must not own an uncommitted borrowed command")
        let resumed = try renderer.render()
        resumed.commandBuffer.waitUntilCompleted()
        XCTAssertEqual(resumed.commandBuffer.status, .completed)
    }

    func testBoundedSubmissionsRecoverCapacityAfterCompletion() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try renderer(device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let event = try XCTUnwrap(device.makeSharedEvent())
        let gate = try XCTUnwrap(queue.makeCommandBuffer())
        let firstLease = try renderer.encode(into: gate)
        gate.encodeWaitForEvent(event, value: 1)
        gate.commit()
        defer { event.signaledValue = 1 }
        var frames: [FrameSubmission] = []
        for index in 0..<3 { frames.append(try renderer.render(frame: FrameState(time: 0, delta: 0, frameIndex: UInt64(index)))) }
        XCTAssertThrowsError(try renderer.render()) { error in
            XCTAssertEqual(error as? RenderSubmissionError, .capacityExceeded)
        }
        XCTAssertEqual(Set(frames.map { ObjectIdentifier($0.output.texture) }).count, 3)
        XCTAssertFalse(frames[0].output.texture === firstLease.texture)
        event.signaledValue = 1
        for frame in frames {
            frame.commandBuffer.waitUntilCompleted()
            XCTAssertEqual(frame.commandBuffer.status, .completed)
        }
        // Metal invokes completion handlers before waitUntilCompleted returns.
        let recovered = try renderer.render()
        recovered.commandBuffer.waitUntilCompleted()
        XCTAssertEqual(recovered.commandBuffer.status, .completed)
        withExtendedLifetime(firstLease) {}
    }

    func testDelayedConsumerReadsRetainedOutputAfterLaterFrames() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try renderer(device)
        let first = try renderer.render()
        first.commandBuffer.waitUntilCompleted()
        for _ in 0..<6 {
            let later = try renderer.render()
            later.commandBuffer.waitUntilCompleted()
            XCTAssertFalse(later.output.texture === first.output.texture)
        }
        let queue = first.commandBuffer.commandQueue
        let consumer = try XCTUnwrap(queue.makeCommandBuffer())
        let stride = ((257 * 8 + 255) / 256) * 256
        let staging = try XCTUnwrap(device.makeBuffer(length: stride * 129, options: .storageModeShared))
        let blit = try XCTUnwrap(consumer.makeBlitCommandEncoder())
        blit.copy(from: first.output.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0,y: 0,z: 0),
            sourceSize: MTLSize(width: 257,height: 129,depth: 1), to: staging, destinationOffset: 0,
            destinationBytesPerRow: stride, destinationBytesPerImage: stride * 129)
        blit.endEncoding()
        consumer.commit()
        consumer.waitUntilCompleted()
        XCTAssertEqual(consumer.status, .completed)
        let words = staging.contents().assumingMemoryBound(to: UInt16.self)
        for (x,y,expected) in [(8,8,[Float(1),0,0,1]), (248,8,[Float(0),1,0,1]),
                                (8,120,[Float(0),0,1,1]), (248,120,[Float(1),1,0,1])] {
            for channel in 0..<4 {
                XCTAssertEqual(Float(Float16(bitPattern: words[y * stride / 2 + x * 4 + channel])), expected[channel], accuracy: 0.004)
            }
        }
    }
}
