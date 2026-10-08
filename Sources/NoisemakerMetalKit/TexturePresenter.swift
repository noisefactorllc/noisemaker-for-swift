import Foundation
import Metal
import Noisemaker

/// Converts a raw graph texture to the upstream presented orientation entirely
/// on the GPU. Same-size copies use nearest sampling; scaled copies use linear.
public final class TexturePresenter {
    public let device: MTLDevice
    public let pixelFormat: MTLPixelFormat
    private let pipeline: MTLRenderPipelineState
    private let nearest: MTLSamplerState
    private let linear: MTLSamplerState

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex presentVertex(uint index [[vertex_id]]) {
            const float2 positions[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
            Vertex result;
            result.position = float4(positions[index], 0, 1);
            result.uv = positions[index] * 0.5 + 0.5;
            return result;
        }
        fragment float4 presentFragment(Vertex v [[stage_in]],
            texture2d<float> texture [[texture(0)]], sampler sampling [[sampler(0)]]) {
            return texture.sample(sampling, v.uv);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "presentVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "presentFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let sampler = MTLSamplerDescriptor()
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        sampler.minFilter = .nearest
        sampler.magFilter = .nearest
        guard let nearest = device.makeSamplerState(descriptor: sampler) else {
            throw GraphDiagnostic.missing("presentation nearest sampler")
        }
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        guard let linear = device.makeSamplerState(descriptor: sampler) else {
            throw GraphDiagnostic.missing("presentation linear sampler")
        }
        self.nearest = nearest
        self.linear = linear
    }

    /// Does not commit or wait. The target must be a distinct renderable texture.
    public func encode(source: MTLTexture, target: MTLTexture, into command: MTLCommandBuffer) throws {
        guard source.device === device, target.device === device,
              command.device === device, source !== target,
              target.pixelFormat == pixelFormat, target.sampleCount == 1,
              source.textureType == .type2D, target.textureType == .type2D,
              source.usage.contains(.shaderRead), target.usage.contains(.renderTarget) else {
            throw GraphDiagnostic.invalid("presentation textures or command buffer are incompatible")
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("presentation render encoder")
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        let sameSize = source.width == target.width && source.height == target.height
        encoder.setFragmentSamplerState(sameSize ? nearest : linear, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // Also support caller-owned command buffers with unretained references.
        let resources: [AnyObject] = [source, target, pipeline, nearest, linear]
        let lifetime = PresentationResources(resources)
        command.addCompletedHandler { _ in withExtendedLifetime(lifetime) {} }
    }
}
private final class PresentationResources: @unchecked Sendable {
    let objects: [AnyObject]
    init(_ objects: [AnyObject]) { self.objects = objects }
}
