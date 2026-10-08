import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct MetalVariantCacheGPUTests {
    private let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 fullTriangle(uint id [[vertex_id]]) {
            float2 points[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
            return float4(points[id], 0, 1);
        }
        fragment float4 red() { return float4(1, 0, 0, 1); }
        fragment float4 green() { return float4(0, 1, 0, 1); }
        kernel void computeOne(uint id [[thread_position_in_grid]]) {}
        kernel void computeTwo(uint id [[thread_position_in_grid]]) {}
        """

    private func descriptor(vertex: MTLFunction, fragment: MTLFunction,
                            format: MTLPixelFormat = .rgba8Unorm,
                            blend: Bool = false,
                            topology: MTLPrimitiveTopologyClass = .triangle,
                            depth: Bool = false) -> MTLRenderPipelineDescriptor {
        let result = MTLRenderPipelineDescriptor()
        result.vertexFunction = vertex
        result.fragmentFunction = fragment
        result.colorAttachments[0].pixelFormat = format
        result.colorAttachments[0].isBlendingEnabled = blend
        result.inputPrimitiveTopology = topology
        if depth { result.depthAttachmentPixelFormat = .depth32Float }
        return result
    }

    private func renderedPixel(_ pipeline: MTLRenderPipelineState,
                               device: MTLDevice) throws -> [UInt8] {
        let textureSpec = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 4, height: 4, mipmapped: false)
        textureSpec.storageMode = .shared
        textureSpec.usage = .renderTarget
        let texture = try requireValue(device.makeTexture(descriptor: textureSpec))
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = try requireValue(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed)
        if let error = command.error { throw error }
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        texture.getBytes(&pixels, bytesPerRow: 4 * 4,
            from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        return Array(pixels[0..<4])
    }

    @Test func fullFunctionAndPipelineStateKeysKeepVariantsIsolated() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let cache = MetalVariantCache(maxFunctions: 8, maxPipelines: 8,
                                      maxSourceBytes: 64 * 1024)
        let vertex = try cache.function(device: device, source: source, name: "fullTriangle")
        let red = try cache.function(device: device, source: source, name: "red")
        let green = try cache.function(device: device, source: source, name: "green")
        expectTrue(red !== green)
        expectTrue(try cache.function(device: device, source: source, name: "red") === red)
        let redPipeline = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: red))
        let repeated = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: red))
        expectTrue(redPipeline === repeated)
        let greenPipeline = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: green))
        expectFalse(redPipeline === greenPipeline)
        expectEqual(try renderedPixel(redPipeline, device: device), [255, 0, 0, 255])
        expectEqual(try renderedPixel(greenPipeline, device: device), [0, 255, 0, 255])
        let blend = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: red, blend: true))
        let point = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: red, topology: .point))
        let depth = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: red, depth: true),
            depthCompare: .less, depthWrite: true)
        let half = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: red, format: .rgba16Float))
        expectFalse(blend === redPipeline)
        expectFalse(point === redPipeline)
        expectFalse(depth === redPipeline)
        expectFalse(half === redPipeline)
        expectEqual(cache.snapshot.renderHits, 1)
        let altered = source.replacingOccurrences(of: "float4(1, 0, 0, 1)",
            with: "float4(0, 0, 1, 1)")
        let blueFunction = try cache.function(device: device, source: altered, name: "red")
        let bluePipeline = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: blueFunction))
        expectFalse(bluePipeline === redPipeline)
        expectEqual(try renderedPixel(bluePipeline, device: device), [0, 0, 255, 255])
    }

    @Test func boundedEvictionAndComputeEntryIsolation() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let cache = MetalVariantCache(maxFunctions: 2, maxPipelines: 1,
                                      maxSourceBytes: 64 * 1024)
        let vertex = try cache.function(device: device, source: source, name: "fullTriangle")
        let red = try cache.function(device: device, source: source, name: "red")
        let first = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: red))
        expectTrue(try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: red)) === first)
        let green = try cache.function(device: device, source: source, name: "green")
        _ = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: green))
        expectEqual(cache.snapshot.renders, 1)
        _ = try cache.renderPipeline(device: device,
            descriptor: descriptor(vertex: vertex, fragment: red))
        expectEqual(cache.snapshot.renderHits, 1)
        expectEqual(cache.snapshot.renders, 1)
        expectEqual(cache.snapshot.functions, 2)
        expectEqual(try renderedPixel(first, device: device), [255, 0, 0, 255],
                    "eviction must not invalidate an active pipeline")

        let computeOne = try cache.function(device: device, source: source, name: "computeOne")
        let computeTwo = try cache.function(device: device, source: source, name: "computeTwo")
        let firstCompute = try cache.computePipeline(device: device, function: computeOne)
        expectTrue(try cache.computePipeline(device: device, function: computeOne) === firstCompute)
        let secondCompute = try cache.computePipeline(device: device, function: computeTwo)
        expectFalse(firstCompute === secondCompute)
        expectEqual(cache.snapshot.computes, 1)
        expectEqual(cache.snapshot.computeHits, 1)
    }
}
