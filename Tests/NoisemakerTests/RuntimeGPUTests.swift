import Foundation
import Metal
import XCTest
@testable import Noisemaker

final class RuntimeGPUTests: XCTestCase {
    private var reference: URL {
        if let path = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/reference")
    }

    private func renderer(_ name: String, device: MTLDevice) throws -> NoisemakerRenderer {
        let graph = try RenderGraph(exportedCaseData:
            Data(contentsOf: reference.appendingPathComponent("cases/\(name).json")))
        let vertex = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: reference.appendingPathComponent("default-vertex.json"))) as? [String: Any])
        return try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 257, height: 129),
            defaultVertexWGSL: try XCTUnwrap(vertex["wgsl"] as? String),
            vertexEntryPoint: try XCTUnwrap(vertex["entryPoint"] as? String))
    }

    private func readback(_ texture: MTLTexture, into command: MTLCommandBuffer,
                          device: MTLDevice) throws -> (MTLBuffer, Int) {
        let bytesPerPixel = texture.pixelFormat == .rgba8Unorm ? 4 : 8
        let rowBytes = ((texture.width * bytesPerPixel + 255) / 256) * 256
        let buffer = try XCTUnwrap(device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        return (buffer, rowBytes)
    }

    private func readback(_ lease: OutputLease, into command: MTLCommandBuffer,
                          device: MTLDevice) throws -> (MTLBuffer, Int) {
        try readback(lease.texture, into: command, device: device)
    }

    private func pixel(_ buffer: MTLBuffer, rowBytes: Int, x: Int, y: Int,
                       format: MTLPixelFormat = .rgba16Float) -> [Float] {
        if format == .rgba8Unorm {
            let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
            return (0..<4).map { c in Float(bytes[y * rowBytes + x * 4 + c]) / 255 }
        }
        let words = buffer.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<4).map { c in Float(Float16(bitPattern: words[y * rowBytes / 2 + x * 4 + c])) }
    }

    func testSolidGraphEncodesUpstreamPassesAndKeepsDistinctOutputs() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("solid", device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let first = try renderer.encode(into: command)
        let (buffer1, stride1) = try readback(first, into: command, device: device)
        command.commit()
        let secondCommand = try XCTUnwrap(queue.makeCommandBuffer())
        let second = try renderer.encode(into: secondCommand)
        XCTAssertFalse(first.texture === second.texture)
        XCTAssertEqual(first.texture.pixelFormat, .rgba16Float)
        let (buffer2, stride2) = try readback(second, into: secondCommand, device: device)
        secondCommand.commit()
        secondCommand.waitUntilCompleted()
        command.waitUntilCompleted()
        XCTAssertEqual(secondCommand.status, .completed)
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        for (buffer, stride) in [(buffer1, stride1), (buffer2, stride2)] {
            for (x, y) in [(0, 0), (128, 64), (256, 128)] {
                let rgba = pixel(buffer, rowBytes: stride, x: x, y: y)
                for (actual, expected) in zip(rgba, [Float(0.2), 0.6, 0.9, 1]) {
                    XCTAssertTrue(actual.isFinite)
                    XCTAssertLessThan(abs(actual - expected), 0.004)
                }
            }
        }
    }

    func testAsymmetricMarkerRunsThroughGraphBlit() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("marker", device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: command)
        let (buffer, stride) = try readback(lease, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let corners = [(8, 8), (248, 8), (8, 120), (248, 120)].map {
            pixel(buffer, rowBytes: stride, x: $0.0, y: $0.1)
        }
        let expected: [[Float]] = [[1, 0, 0, 1], [0, 1, 0, 1],
                                   [0, 0, 1, 1], [1, 1, 0, 1]]
        for (actual, wanted) in zip(corners, expected) {
            for (component, reference) in zip(actual, wanted) {
                XCTAssertTrue(component.isFinite)
                XCTAssertLessThan(abs(component - reference), 0.004)
            }
        }
    }
    func testComputeRidgeWritesAndConvertsStorageBuffer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("computeFilter", device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let lease = try renderer.encode(frame: FrameState(time: 0.25, delta: 0, frameIndex: 7), into: command)
        let input = try XCTUnwrap(lease.graphTexture("node_0_out"))
        let ridged = try XCTUnwrap(lease.graphTexture("node_1_out"))
        let (inputBuffer, inputRow) = try readback(input, into: command, device: device)
        let (outputBuffer, outputRow) = try readback(ridged, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        for (x, y) in [(8, 8), (64, 32), (128, 64), (200, 100), (248, 120)] {
            let source = pixel(inputBuffer, rowBytes: inputRow, x: x, y: y)
            let actual = pixel(outputBuffer, rowBytes: outputRow, x: x, y: y)
            for c in 0..<3 {
                let expected = max(0, min(1, 1 - abs(source[c] - 0.4) / 0.6))
                XCTAssertTrue(actual[c].isFinite)
                XCTAssertLessThan(abs(actual[c] - expected), 0.006)
            }
            XCTAssertLessThan(abs(actual[3] - 1), 0.004)
        }
    }

    func testMRTWritesDistinctOrderedAttachmentsThenCombinesThem() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("mrtProbe", device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: command)
        let first = try XCTUnwrap(lease.graphTexture("node_0_firstTarget"))
        let second = try XCTUnwrap(lease.graphTexture("node_0_secondTarget"))
        let combined = try XCTUnwrap(lease.graphTexture("node_0_out"))
        XCTAssertEqual(first.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(second.pixelFormat, .rgba8Unorm)
        XCTAssertFalse(first === second)
        let (firstBuffer, firstRow) = try readback(first, into: command, device: device)
        let (secondBuffer, secondRow) = try readback(second, into: command, device: device)
        let (combinedBuffer, combinedRow) = try readback(combined, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        for (x, y) in [(40, 20), (128, 64), (200, 100)] {
            let a = pixel(firstBuffer, rowBytes: firstRow, x: x, y: y, format: .rgba8Unorm)
            let b = pixel(secondBuffer, rowBytes: secondRow, x: x, y: y, format: .rgba8Unorm)
            let c = pixel(combinedBuffer, rowBytes: combinedRow, x: x, y: y)
            XCTAssertLessThan(abs(a[1]), 0.004)
            XCTAssertLessThan(abs(b[0]), 0.004)
            XCTAssertLessThan(abs(c[0] - a[0]), 0.005)
            XCTAssertLessThan(abs(c[1] - b[1]), 0.005)
            XCTAssertLessThan(abs(c[2] - (1 - (Float(x) + 0.5) / 257)), 0.005)
            XCTAssertLessThan(abs(c[3] - 1), 0.004)
        }
    }

    func testMultipassBlurUsesRgba8IntermediateAndChangesImage() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("multipassBlur", device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let lease = try renderer.encode(frame: FrameState(time: 0.25, delta: 0, frameIndex: 7), into: command)
        let input = try XCTUnwrap(lease.graphTexture("node_0_out"))
        let intermediate = try XCTUnwrap(lease.graphTexture("node_1__blurTemp"))
        let output = try XCTUnwrap(lease.graphTexture("node_1_out"))
        XCTAssertEqual(intermediate.pixelFormat, .rgba8Unorm)
        let (inputBuffer, inputRow) = try readback(input, into: command, device: device)
        let (outputBuffer, outputRow) = try readback(output, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let samples = [(8, 8), (32, 20), (64, 32), (128, 64), (200, 100), (248, 120)]
        let differences = samples.map { point -> Float in
            let source = pixel(inputBuffer, rowBytes: inputRow, x: point.0, y: point.1)
            let result = pixel(outputBuffer, rowBytes: outputRow, x: point.0, y: point.1)
            return zip(source, result).map { pair in abs(pair.0 - pair.1) }.max() ?? 0
        }
        XCTAssertTrue(differences.contains { $0 > 0.01 }, "Blur must change actual source pixels")
        XCTAssertTrue(differences.allSatisfy(\.isFinite))
    }

    func testOrdinarySurfaceFractionalSamplesUseNearestFiltering() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("samplerProbe", device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: command)
        let sampled = try XCTUnwrap(lease.graphTexture("node_0_out"))
        let (buffer, stride) = try readback(sampled, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        // The source graph samples at a quarter-pixel offset from a 1-pixel
        // checkerboard. Linear filtering would produce gray at these points.
        for (x, y) in [(100, 64), (101, 64), (100, 65), (101, 65)] {
            let expected: Float = ((x + y) & 1) == 0 ? 0 : 1
            let rgba = pixel(buffer, rowBytes: stride, x: x, y: y)
            for component in rgba.prefix(3) {
                XCTAssertLessThan(abs(component - expected), 0.004)
            }
            XCTAssertLessThan(abs(rgba[3] - 1), 0.004)
        }
    }

}
