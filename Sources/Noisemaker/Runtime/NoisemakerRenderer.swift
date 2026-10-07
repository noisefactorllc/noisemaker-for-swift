import Foundation
import Metal

public struct RenderSize: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw GraphDiagnostic.invalid("render size must be 1...16384 in each dimension")
        }
        self.width = width
        self.height = height
    }
}

public struct FrameState: Sendable {
    public let time: Double
    public let delta: Double
    public let frameIndex: UInt64
    public init(time: Double, delta: Double, frameIndex: UInt64) {
        self.time = time
        self.delta = delta
        self.frameIndex = frameIndex
    }
    public static let zero = FrameState(time: 0, delta: 0, frameIndex: 0)
}

/// Keeps this invocation's distinct render targets and argument buffers alive.
/// The caller owns the command buffer and must not read the texture before it completes.
public final class OutputLease {
    public let texture: MTLTexture
    public let size: RenderSize
    private let resources: [AnyObject]
    private let graphTextures: [String: MTLTexture]
    fileprivate init(texture: MTLTexture, size: RenderSize,
                     resources: [AnyObject], graphTextures: [String: MTLTexture]) {
        self.texture = texture
        self.size = size
        self.resources = resources
        self.graphTextures = graphTextures
    }
    func graphTexture(_ name: String) -> MTLTexture? { graphTextures[name] }
}

public final class NoisemakerRenderer {
    public let graph: RenderGraph
    public let size: RenderSize
    public let device: MTLDevice
    private let passes: [PreparedRenderPass]
    private let sampler: MTLSamplerState
    private let bufferBridge: BufferToTextureBridge?
    let frameCoordinator = FrameCoordinator()

    public init(device: MTLDevice, graph: RenderGraph, size: RenderSize,
                defaultVertexWGSL: String, vertexEntryPoint: String = "vs_main") throws {
        self.device = device
        self.graph = graph
        self.size = size
        try graph.validateDimensions(for: size)
        let translator = ShaderTranslator()
        let vertexTranslation = try translator.translate(wgsl: defaultVertexWGSL,
            entryPoint: vertexEntryPoint, stage: .vertex)
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let vertexLibrary = try device.makeLibrary(source: vertexTranslation.source, options: options)
        guard let vertex = vertexLibrary.makeFunction(name: vertexTranslation.mslEntryPoint) else {
            throw GraphDiagnostic.missing("translated default vertex entry point")
        }
        self.passes = try graph.passes.map { pass in
            guard let program = graph.programs[pass.program] else {
                throw GraphDiagnostic.missing("program \(pass.program)")
            }
            let formats = try pass.outputs.map { output -> MTLPixelFormat in
                guard let name = output.value.stringValue else {
                    throw GraphDiagnostic.invalid("pass \(pass.id) has non-string output")
                }
                if name == "global_\(graph.renderSurface)" { return .rgba16Float }
                guard let texture = graph.textures.first(where: { $0.key == name }) else {
                    throw GraphDiagnostic.missing("pass \(pass.id) output texture \(name)")
                }
                return try Self.pixelFormat(texture.format)
            }
            return try ShaderCompiler.prepare(pass: pass, program: program,
                vertex: vertex, device: device, translator: translator,
                pixelFormats: formats)
        }
        self.bufferBridge = graph.programs.values.contains(where: { $0.stage == .compute })
            ? try BufferToTextureBridge(device: device, vertex: vertex, translator: translator)
            : nil
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .nearest
        descriptor.magFilter = .nearest
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("Metal sampler")
        }
        self.sampler = sampler
    }

    /// Encodes one graph frame into a borrowed, uncommitted command buffer.
    /// Every call allocates a separate output so a retained lease cannot be overwritten.
    public func encode(frame: FrameState = .zero, into commandBuffer: MTLCommandBuffer) throws -> OutputLease {
        guard commandBuffer.device === device else {
            throw GraphDiagnostic.invalid("command buffer belongs to another Metal device")
        }
        guard commandBuffer.status == .notEnqueued else {
            throw GraphDiagnostic.invalid("command buffer must be uncommitted")
        }
        guard frame.time.isFinite, frame.delta.isFinite else {
            throw GraphDiagnostic.invalid("frame time and delta must be finite")
        }
        try frameCoordinator.beginEncode(commandBuffer)
        var succeeded = false
        var retained: [AnyObject] = [sampler]
        retained.append(contentsOf: passes.map { $0.pipeline.retainedObject })
        if let bufferBridge { retained.append(bufferBridge) }
        defer {
            if !succeeded {
                // A caller may still commit the partially encoded borrowed buffer.
                FrameCoordinator.keepAlive(retained, through: commandBuffer)
                frameCoordinator.discard(commandBuffer)
            }
        }
        var targets: [String: MTLTexture] = [:]
        let parameters = graph.dimensionParameters
        for texture in graph.textures {
            let target = try makeTexture(named: texture.key, spec: texture, parameters: parameters)
            targets[texture.key] = target
            retained.append(target)
        }
        let outputName = "global_\(graph.renderSurface)"
        guard targets[outputName] == nil else {
            throw GraphDiagnostic.invalid("render surface collides with graph texture")
        }
        let output = try makeTexture(named: outputName, spec: nil, parameters: parameters)
        targets[outputName] = output
        retained.append(output)
        for prepared in passes {
            switch prepared.pipeline {
            case .render(let pipeline):
                try encodeRender(prepared, pipeline: pipeline, targets: targets,
                    frame: frame, command: commandBuffer, retained: &retained)
            case .compute(let pipeline):
                try encodeCompute(prepared, pipeline: pipeline, targets: targets,
                    frame: frame, command: commandBuffer, retained: &retained)
            }
        }
        FrameCoordinator.keepAlive(retained, through: commandBuffer)
        succeeded = true
        return OutputLease(texture: output, size: size,
            resources: retained, graphTextures: targets)
    }

    private func uniformBuffer(_ resource: ShaderResource, pass: GraphPass,
                               frame: FrameState, retained: inout [AnyObject]) throws -> MTLBuffer {
        guard let plan = resource.uniformPlan else {
            throw GraphDiagnostic.missing("pass \(pass.id) uniform plan \(resource.name)")
        }
        let data = try plan.encode(name: resource.name, pass: pass, frame: frame, size: size)
        guard let buffer = data.withUnsafeBytes({ bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: data.count,
                options: .storageModeShared) }
        }) else { throw GraphDiagnostic.missing("Metal uniform buffer for \(pass.id)") }
        retained.append(buffer)
        return buffer
    }

    private func inputTexture(_ resource: ShaderResource, pass: GraphPass,
                              targets: [String: MTLTexture]) throws -> MTLTexture {
        guard let name = pass.inputs.first(where: { $0.key == resource.name })?.value.stringValue,
              let texture = targets[name] else {
            throw GraphDiagnostic.missing("pass \(pass.id) texture \(resource.name)")
        }
        return texture
    }

    private func encodeRender(_ prepared: PreparedRenderPass, pipeline: MTLRenderPipelineState,
                              targets: [String: MTLTexture], frame: FrameState,
                              command: MTLCommandBuffer, retained: inout [AnyObject]) throws {
        let pass = prepared.graphPass
        let attachments = try pass.outputs.map { output -> MTLTexture in
            guard let name = output.value.stringValue, let target = targets[name] else {
                throw GraphDiagnostic.missing("pass \(pass.id) output target")
            }
            return target
        }
        guard let first = attachments.first,
              attachments.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw GraphDiagnostic.unsupported("pass \(pass.id) MRT attachments have different dimensions")
        }
        let descriptor = MTLRenderPassDescriptor()
        for (index, target) in attachments.enumerated() {
            descriptor.colorAttachments[index].texture = target
            descriptor.colorAttachments[index].loadAction = .clear
            descriptor.colorAttachments[index].storeAction = .store
            descriptor.colorAttachments[index].clearColor = MTLClearColorMake(0, 0, 0, 0)
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("Metal render encoder for \(pass.id)")
        }
        encoder.label = pass.id
        encoder.setRenderPipelineState(pipeline)
        do {
            for resource in prepared.resources {
                switch resource.kind {
                case .uniform:
                    let buffer = try uniformBuffer(resource, pass: pass, frame: frame, retained: &retained)
                    encoder.setFragmentBuffer(buffer, offset: 0, index: resource.slot)
                case .texture:
                    encoder.setFragmentTexture(try inputTexture(resource, pass: pass, targets: targets),
                        index: resource.slot)
                case .sampler:
                    encoder.setFragmentSamplerState(sampler, index: resource.slot)
                default:
                    throw GraphDiagnostic.unsupported("pass \(pass.id) render binding \(resource.name)")
                }
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        } catch {
            encoder.endEncoding()
            throw error
        }
    }

    private func encodeCompute(_ prepared: PreparedRenderPass, pipeline: MTLComputePipelineState,
                               targets: [String: MTLTexture], frame: FrameState,
                               command: MTLCommandBuffer, retained: inout [AnyObject]) throws {
        let pass = prepared.graphPass
        guard let name = pass.outputs.first?.value.stringValue,
              let target = targets[name], let bridge = bufferBridge else {
            throw GraphDiagnostic.missing("pass \(pass.id) compute output or conversion pipeline")
        }
        guard target.width == size.width, target.height == size.height else {
            throw GraphDiagnostic.unsupported("pass \(pass.id) compute output must be screen-sized for upstream buffer indexing")
        }
        let byteCount = target.width * target.height * 4 * MemoryLayout<Float>.size
        guard byteCount > 0, byteCount <= Int(UInt32.max),
              let storage = device.makeBuffer(length: byteCount, options: .storageModePrivate) else {
            throw GraphDiagnostic.missing("pass \(pass.id) output storage buffer")
        }
        retained.append(storage)
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GraphDiagnostic.missing("Metal compute encoder for \(pass.id)")
        }
        encoder.label = pass.id
        encoder.setComputePipelineState(pipeline)
        do {
            for resource in prepared.resources {
                switch resource.kind {
                case .uniform:
                    let buffer = try uniformBuffer(resource, pass: pass, frame: frame, retained: &retained)
                    encoder.setBuffer(buffer, offset: 0, index: resource.slot)
                case .storage:
                    encoder.setBuffer(storage, offset: 0, index: resource.slot)
                case .texture:
                    let source = try inputTexture(resource, pass: pass, targets: targets)
                    guard source.width == target.width && source.height == target.height else {
                        throw GraphDiagnostic.unsupported("pass \(pass.id) compute input/output dimensions differ")
                    }
                    encoder.setTexture(source, index: resource.slot)
                default:
                    throw GraphDiagnostic.unsupported("pass \(pass.id) compute binding \(resource.name)")
                }
            }
            if prepared.needsStorageSizes {
                var immediate = [UInt32](repeating: 0, count: 16)
                for entry in prepared.storageSizeEntries {
                    immediate[Int(entry.index)] = UInt32(storage.length)
                }
                immediate.withUnsafeBytes {
                    encoder.setBytes($0.baseAddress!, length: $0.count, index: 30)
                }
            }
            let (x, y, z) = prepared.workgroupSize
            guard x == 8, y == 8, z == 1,
                  UInt64(x) * UInt64(y) * UInt64(z) <= UInt64(pipeline.maxTotalThreadsPerThreadgroup) else {
                throw GraphDiagnostic.unsupported("pass \(pass.id) compute workgroup must match upstream default 8x8x1")
            }
            let threads = MTLSize(width: 8, height: 8, depth: 1)
            let groups = MTLSize(width: (target.width + 7) / 8,
                height: (target.height + 7) / 8, depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        } catch {
            encoder.endEncoding()
            throw error
        }
        retained.append(contentsOf: try bridge.encode(storage, into: target, command: command))
    }

    private static func pixelFormat(_ format: String) throws -> MTLPixelFormat {
        switch format {
        case "rgba16f": return .rgba16Float
        case "rgba8", "rgba8unorm": return .rgba8Unorm
        case "rgba32f": return .rgba32Float
        default: throw GraphDiagnostic.unsupported("texture format \(format)")
        }
    }

    private func makeTexture(named name: String, spec: GraphTexture?, parameters: [String: Double]) throws -> MTLTexture {
        let width = try spec?.width.resolve(screen: size.width, parameters: parameters) ?? size.width
        let height = try spec?.height.resolve(screen: size.height, parameters: parameters) ?? size.height
        let format = try spec.map { try Self.pixelFormat($0.format) } ?? .rgba16Float
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("Metal texture \(name)")
        }
        texture.label = name
        return texture
    }

}
