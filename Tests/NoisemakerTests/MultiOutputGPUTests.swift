import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct MultiOutputGPUTests {
    @Test func selectedEarlierGlobalSurfaceIsPresented() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let graph = try NoisemakerCompiler().compile(source: """
            search synth
            solid(color: #ff0000).write(o0)
            solid(color: #0000ff).write(o1)
            render(o0)
            """)
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 32, height: 24))
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: command)
        let rowBytes = 256
        let buffer = try requireValue(device.makeBuffer(length: rowBytes * 24,
            options: .storageModeShared))
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: lease.texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 32, height: 24, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * 24)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let half = buffer.contents().assumingMemoryBound(to: UInt16.self)
        let pixel = (0..<4).map { Float(Float16(bitPattern: half[12 * rowBytes / 2 + 16 * 4 + $0])) }
        expectLess(abs(pixel[0] - 1), 0.004)
        expectLess(abs(pixel[1]), 0.004)
        expectLess(abs(pixel[2]), 0.004)
        expectLess(abs(pixel[3] - 1), 0.004)
    }
}
