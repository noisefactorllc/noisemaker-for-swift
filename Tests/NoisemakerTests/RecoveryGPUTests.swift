import Foundation
import MetalKit
import Testing
@testable import Noisemaker
@testable import NoisemakerMetalKit

@Suite(.serialized)
struct RecoveryGPUTests {
    @MainActor @Test func hundredCompileRenderResizeDisposeCycles() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = try NoisemakerCompiler()
        let queue = try #require(device.makeCommandQueue())
        var held: [OutputLease] = []
        var sizes: [RenderSize] = []
        var baseline: Int?
        var largestOwnedAllocation = 0
        for cycle in 0..<100 {
            weak var retired: NoisemakerRenderer?
            weak var disposed: NoisemakerViewRenderer?
            try autoreleasepool {
                let graph = try compiler.compile(source: "search synth\nsolid(color: [0.2, 0.6, 0.9]).write(o0)\nrender(o0)\n")
                let width = 65 + (cycle % 3) * 2, height = 33 + (cycle % 5) * 2
                let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
                view.isPaused = true
                view.drawableSize = CGSize(width: width, height: height)
                let host = try NoisemakerViewRenderer(view: view, graph: graph)
                disposed = host
                retired = host.renderer
                let fence = try #require(device.makeSharedEvent())
                defer { fence.signaledValue = 1 }
                let command = try #require(queue.makeCommandBufferWithUnretainedReferences())
                command.encodeWaitForEvent(fence, value: 1)
                let output = try host.renderer.encode(into: command)
                command.commit()
                // A pending feedback frame cannot migrate. The callback records
                // the error and keeps the old renderer for the next draw retry.
                host.mtkView(view, drawableSizeWillChange:
                    CGSize(width: width + 8, height: height + 4))
                #expect(host.renderer === retired)
                #expect(host.lastError != nil)
                // The completed frame keeps its resources after the retry swaps.
                fence.signaledValue = 1
                command.waitUntilCompleted()
                try host.resize(to: RenderSize(width: width + 8, height: height + 4))
                #expect(host.renderer.size.width == width + 8)
                #expect(host.frameIndex == 0)
                let resized = try host.renderer.render()
                resized.commandBuffer.waitUntilCompleted()
                #expect(command.status == .completed)
                #expect(resized.commandBuffer.status == .completed)
                held.append(output)
                sizes.append(try RenderSize(width: width, height: height))
                if held.count == 10 {
                    // Consume outputs after later graphs and sizes have already run.
                    for (lease, expectedSize) in zip(held, sizes) {
                        #expect(lease.size == expectedSize)
                        let rowBytes = ((expectedSize.width * 8 + 255) / 256) * 256
                        let readback = try #require(device.makeBuffer(length: rowBytes * expectedSize.height, options: .storageModeShared))
                        let copy = try #require(queue.makeCommandBuffer())
                        let blit = try #require(copy.makeBlitCommandEncoder())
                        blit.copy(from: lease.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x:0,y:0,z:0),
                            sourceSize: MTLSize(width:expectedSize.width,height:expectedSize.height,depth:1),
                            to: readback,destinationOffset:0,destinationBytesPerRow:rowBytes,
                            destinationBytesPerImage:rowBytes * expectedSize.height)
                        blit.endEncoding(); copy.commit(); copy.waitUntilCompleted()
                        #expect(copy.status == .completed)
                        let pixel = readback.contents().assumingMemoryBound(to: UInt16.self)
                        for (component, expected) in [0.2,0.6,0.9,1.0].enumerated() {
                            #expect(abs(Double(Float16(bitPattern:pixel[component])) - expected) < 0.001)
                        }
                    }
                    held.removeAll(); sizes.removeAll()
                }
            }
            #expect(retired == nil, "cycle \(cycle): old renderer survived completion")
            #expect(disposed == nil, "cycle \(cycle): view adapter survived teardown")
            if cycle == 9 { baseline = device.currentAllocatedSize }
            if cycle >= 10 { largestOwnedAllocation = max(largestOwnedAllocation, device.currentAllocatedSize) }
        }
        #expect(held.isEmpty)
        // Device compiler caches may persist; framebuffer allocations must remain bounded.
        #expect(largestOwnedAllocation <= (baseline ?? 0) + 64 * 1024 * 1024)
    }
}
