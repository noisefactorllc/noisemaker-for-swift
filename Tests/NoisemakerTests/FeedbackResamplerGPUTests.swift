import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct FeedbackResamplerGPUTests {
    @Test func oddDimensionsUseWebGL2CenterNearestMappingWithoutFlip() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let queue = try requireValue(device.makeCommandQueue())
        for (width, height, outWidth, outHeight) in [(7, 5, 13, 9), (13, 9, 7, 5)] {
            let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                width: width, height: height, mipmapped: false)
            sourceDescriptor.storageMode = .shared
            sourceDescriptor.usage = .shaderRead
            let source = try requireValue(device.makeTexture(descriptor: sourceDescriptor))
            var input = [Float](repeating: 0, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                input[i] = Float(x); input[i+1] = Float(y); input[i+2] = Float(x + y * width); input[i+3] = 1
            } }
            input.withUnsafeBytes { bytes in
                source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: bytes.baseAddress!, bytesPerRow: width * 16)
            }
            let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                width: outWidth, height: outHeight, mipmapped: false)
            targetDescriptor.storageMode = .shared
            targetDescriptor.usage = [.shaderRead, .renderTarget]
            let target = try requireValue(device.makeTexture(descriptor: targetDescriptor))
            let scaler = try FeedbackResampler(device: device, formats: [.init(MTLPixelFormat.rgba32Float.rawValue)])
            let command = try requireValue(queue.makeCommandBufferWithUnretainedReferences())
            try scaler.encode(source: source, target: target, into: command)
            command.commit(); command.waitUntilCompleted()
            expectEqual(command.status, .completed)
            if let error = command.error { throw error }
            var output = [Float](repeating: 0, count: outWidth * outHeight * 4)
            target.getBytes(&output, bytesPerRow: outWidth * 16,
                from: MTLRegionMake2D(0, 0, outWidth, outHeight), mipmapLevel: 0)
            for y in 0..<outHeight { for x in 0..<outWidth {
                let sx = min(Int((Float(x) + 0.5) * (Float(width) / Float(outWidth))), width - 1)
                let sy = min(Int((Float(y) + 0.5) * (Float(height) / Float(outHeight))), height - 1)
                let start = (y * outWidth + x) * 4, sourceStart = (sy * width + sx) * 4
                expectEqual(Array(output[start..<start+4]), Array(input[sourceStart..<sourceStart+4]))
            } }
        }
    }
    @Test func rgba32floatSourceAliasAllocatesBuddhabrotState() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let graph = try NoisemakerCompiler().compile(source:
            "search synth, points, render\nsolid().buddhabrot().pointsRender().write(o0)\nrender(o0)\n")
        let state = try FeedbackState(device: device, graph: graph, size: RenderSize(width: 33, height: 17))
        let floating = state.targets.filter { $0.key.contains("zState") }
        expectTrue(!floating.isEmpty)
        for texture in floating.values { expectEqual(texture.pixelFormat, .rgba32Float) }
    }
}
