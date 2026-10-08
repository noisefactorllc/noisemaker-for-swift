import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct RollFeedbackGPUTests {
    private func greenPixels(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [Float] {
        expectEqual(texture.pixelFormat, .rgba16Float)
        let rowBytes = texture.width * 8
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
        let words = buffer.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<(texture.width * texture.height)).map {
            Float(Float16(bitPattern: words[$0 * 4 + 1]))
        }
    }

    @Test func midiGridDoesNotMakeRollFeedbackLinear() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let graph = try NoisemakerCompiler().compile(source:
            "search synth\nroll(speed: 2.5).write(o0)\nrender(o0)\n")
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 256, height: 256))
        let midi = try MIDIGrid.snapshot(messages: (0..<16).map { [0x90 | $0, 60, 127] })
        let inputs = AutomationInputs(midi: midi)
        func render(index: Int, delta: Double) throws -> [Float] {
            let command = try requireValue(queue.makeCommandBuffer())
            let lease = try renderer.encode(frame: FrameState(time: Double(index + 1) / 600,
                delta: delta, frameIndex: UInt64(index), inputs: inputs), into: command)
            command.commit()
            command.waitUntilCompleted()
            expectEqual(command.status, .completed)
            if let error = command.error { throw error }
            return try greenPixels(lease.texture, queue: queue)
        }
        let first = try render(index: 0, delta: 0)
        let second = try render(index: 1, delta: 1.0 / 600)
        // At speed 2.5 this frame shifts feedback by 0.533 texels. Source
        // WebGPU treats the uploaded MIDI grid as data, so both samplers in
        // this pass are NEAREST. The prior four-pixel note bar must reach x=4.
        let width = 256
        let litRow = try requireValue((0..<256).first { y in
            first[y * width + 3] > 0.5 && first[y * width + 4] < 0.01
        })
        let base = litRow * width
        expectTrue(second[base + 4] > first[base + 3] * 0.95,
            "feedback at x=4 must keep the preceding bright texel")
    }
}
