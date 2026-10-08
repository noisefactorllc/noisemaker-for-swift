import Foundation
import Metal

/// Mirrors the upstream WebGPU output_buffer fullscreen conversion pass.
final class BufferToTextureBridge {
    private let device: MTLDevice
    private let vertex: MTLFunction
    private let fragment: MTLFunction
    private let needsStorageSize: Bool
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]

    init(device: MTLDevice, vertex: MTLFunction, translator: ShaderTranslator) throws {
        self.device = device
        self.vertex = vertex
        let source = """
        struct BufferToTextureParams {
            width: u32,
            height: u32,
            _pad0: u32,
            _pad1: u32,
        }
        @group(0) @binding(0) var<storage, read> input_buffer: array<f32>;
        @group(0) @binding(1) var<uniform> params: BufferToTextureParams;
        @fragment
        fn fs_main(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
            let x = u32(position.x);
            let y = u32(position.y);
            if (x >= params.width || y >= params.height) {
                return vec4<f32>(0.0, 0.0, 0.0, 1.0);
            }
            let base = (y * params.width + x) * 4u;
            return vec4<f32>(input_buffer[base], input_buffer[base + 1u],
                             input_buffer[base + 2u], input_buffer[base + 3u]);
        }
        """
        let translated = try translator.translate(wgsl: source, entryPoint: "fs_main",
            stage: .fragment, bindings: [
                TintBinding(group: 0, binding: 0, kind: .storage, slot: 0),
                TintBinding(group: 0, binding: 1, kind: .uniform, slot: 1)
            ], bufferSizes: [TintBufferSize(group: 0, binding: 0, index: 0)],
            bufferSizesOffset: 0, immediateSlot: 30)
        let library = try MetalLibraryCache.library(device: device,
            source: translated.source)
        guard let fragment = library.makeFunction(name: translated.mslEntryPoint) else {
            throw GraphDiagnostic.missing("buffer-to-texture fragment function")
        }
        self.fragment = fragment
        self.needsStorageSize = translated.needsStorageBufferSizes
    }

    func encode(_ storage: MTLBuffer, into target: MTLTexture,
                command: MTLCommandBuffer) throws -> [AnyObject] {
        guard storage.length <= Int(UInt32.max),
              target.width <= Int(UInt32.max), target.height <= Int(UInt32.max) else {
            throw GraphDiagnostic.unsupported("buffer-to-texture dimensions exceed shader ABI")
        }
        let pipeline: MTLRenderPipelineState
        if let cached = pipelines[target.pixelFormat] { pipeline = cached }
        else {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "output_buffer-to-texture"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = target.pixelFormat
            let created = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[target.pixelFormat] = created
            pipeline = created
        }
        let params: [UInt32] = [UInt32(target.width), UInt32(target.height), 0, 0]
        guard let uniform = params.withUnsafeBytes({ bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
        }) else { throw GraphDiagnostic.missing("buffer-to-texture params") }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("buffer-to-texture render encoder")
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(storage, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniform, offset: 0, index: 1)
        if needsStorageSize {
            var sizeBlock = [UInt32](repeating: 0, count: 16)
            sizeBlock[0] = UInt32(storage.length)
            sizeBlock.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 30) }
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return [pipeline, uniform]
    }
}
