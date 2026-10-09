import Metal

/// WebGL2's gl.blitFramebuffer(..., GL_NEAREST) resize of persistent surfaces.
/// Fragment position is the destination pixel center, including odd sizes.
final class FeedbackResampler {
    private let pipelines: [UInt: MTLRenderPipelineState]
    init(device: MTLDevice, formats: Set<UInt>) throws {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 resizeVertex(uint index [[vertex_id]]) {
            const float2 points[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
            return float4(points[index],0,1);
        }
        fragment float4 resizeFragment(float4 position [[position]],
            texture2d<float, access::read> source [[texture(0)]],
            constant float4 &dims [[buffer(0)]]) {
            float2 ratio = dims.xy / dims.zw;
            uint2 maximum = uint2(max(dims.xy - 1.0f, float2(0)));
            uint2 coordinate = min(uint2(position.xy * ratio), maximum);
            return source.read(coordinate);
        }
        """
        let library = try MetalLibraryCache.library(device: device, source: source)
        var pipelines: [UInt: MTLRenderPipelineState] = [:]
        for format in formats {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = RuntimeBenchmarkProbe.measure("metalFunctionCreateMS") {
                library.makeFunction(name: "resizeVertex")
            }
            if descriptor.vertexFunction != nil {
                RuntimeBenchmarkProbe.active?.record("metalFunctionCreateCount")
            }
            descriptor.fragmentFunction = RuntimeBenchmarkProbe.measure("metalFunctionCreateMS") {
                library.makeFunction(name: "resizeFragment")
            }
            if descriptor.fragmentFunction != nil {
                RuntimeBenchmarkProbe.active?.record("metalFunctionCreateCount")
            }
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormat(rawValue: format)!
            pipelines[format] = try RuntimeBenchmarkProbe.measure("metalRenderPipelineCompileMS") {
                try device.makeRenderPipelineState(descriptor: descriptor)
            }
            RuntimeBenchmarkProbe.active?.record("metalRenderPipelineCompileCount")
        }
        self.pipelines = pipelines
    }
    func encode(source: MTLTexture, target: MTLTexture, into command: MTLCommandBuffer) throws {
        guard let pipeline = pipelines[target.pixelFormat.rawValue], source !== target,
              source.device === target.device, target.device === command.device else {
            throw GraphDiagnostic.invalid("feedback resample resources are incompatible")
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("feedback resample encoder")
        }
        var dimensions = SIMD4<Float>(Float(source.width), Float(source.height), Float(target.width), Float(target.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&dimensions, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        FrameCoordinator.keepAlive([source, target, pipeline], through: command)
    }
}
