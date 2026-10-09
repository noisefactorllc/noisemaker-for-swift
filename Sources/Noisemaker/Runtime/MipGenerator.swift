import Metal

/// Generates the source WebGL2 mip chain after graph passes have finished.
/// WebGL2 blits each level with NEAREST filtering, including odd dimensions.
final class MipGenerator {
    private let pipelines: [UInt: MTLRenderPipelineState]

    init(device: MTLDevice, formats: Set<UInt>) throws {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 mipVertex(uint index [[vertex_id]]) {
            const float2 points[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
            return float4(points[index],0,1);
        }
        fragment float4 mipFragment(float4 position [[position]],
            texture2d<float, access::read> source [[texture(0)]],
            constant uint2 &destinationSize [[buffer(0)]]) {
            uint2 destination = uint2(position.xy);
            float2 sourceSize = float2(source.get_width(), source.get_height());
            float2 center = float2(destination) + 0.5f;
            uint2 coordinate = min(uint2(floor(center * sourceSize / float2(destinationSize))),
                                   uint2(source.get_width()-1, source.get_height()-1));
            return source.read(coordinate);
        }
        """
        let library = try MetalLibraryCache.library(device: device, source: source)
        var pipelines: [UInt: MTLRenderPipelineState] = [:]
        for format in formats {
            guard let pixelFormat = MTLPixelFormat(rawValue: format) else {
                throw GraphDiagnostic.missing("Metal mipmap shader functions or format")
            }
            guard let vertex = RuntimeBenchmarkProbe.measure("metalFunctionCreateMS", {
                library.makeFunction(name: "mipVertex")
            }) else {
                throw GraphDiagnostic.missing("Metal mipmap shader functions or format")
            }
            RuntimeBenchmarkProbe.active?.record("metalFunctionCreateCount")
            guard let fragment = RuntimeBenchmarkProbe.measure("metalFunctionCreateMS", {
                library.makeFunction(name: "mipFragment")
            }) else {
                throw GraphDiagnostic.missing("Metal mipmap shader functions or format")
            }
            RuntimeBenchmarkProbe.active?.record("metalFunctionCreateCount")
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            pipelines[format] = try MetalVariantCache.shared.renderPipeline(
                device: device, descriptor: descriptor)
        }
        self.pipelines = pipelines
    }

    func encode(texture: MTLTexture, into command: MTLCommandBuffer,
                retained: inout [AnyObject]) throws {
        guard let pipeline = pipelines[texture.pixelFormat.rawValue],
              texture.textureType == .type2D, texture.device === command.device else {
            throw GraphDiagnostic.invalid("mipmap generation texture is incompatible")
        }
        guard texture.mipmapLevelCount > 1 else { return }
        retained.append(pipeline)
        for level in 1..<texture.mipmapLevelCount {
            guard let source = texture.makeTextureView(pixelFormat: texture.pixelFormat,
                    textureType: .type2D, levels: (level - 1)..<level, slices: 0..<1),
                  let target = texture.makeTextureView(pixelFormat: texture.pixelFormat,
                    textureType: .type2D, levels: level..<(level + 1), slices: 0..<1) else {
                throw GraphDiagnostic.missing("Metal mipmap level view \(level)")
            }
            retained.append(source)
            retained.append(target)
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
                throw GraphDiagnostic.missing("Metal mipmap encoder for level \(level)")
            }
            var dimensions = SIMD2<UInt32>(UInt32(target.width), UInt32(target.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBytes(&dimensions, length: MemoryLayout<SIMD2<UInt32>>.size,
                index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }
}
