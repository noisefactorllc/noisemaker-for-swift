import Foundation
import Metal
import CryptoKit

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
    public let inputs: AutomationInputs
    public let hostUniforms: [String: [String: GraphValue]]
    public init(time: Double, delta: Double, frameIndex: UInt64,
                inputs: AutomationInputs = AutomationInputs(),
                hostUniforms: [String: [String: GraphValue]] = [:]) {
        self.time = time
        self.delta = delta
        self.frameIndex = frameIndex
        self.inputs = inputs
        self.hostUniforms = hostUniforms
    }
    public static let zero = FrameState(time: 0, delta: 0, frameIndex: 0)
}

/// Keeps this invocation's distinct render targets and argument buffers alive.
/// The caller owns the command buffer and must not read the texture before it completes.
/// Keep the lease while using its texture; a texture retained alone may be pooled.
public final class OutputLease {
    public let texture: MTLTexture
    public let size: RenderSize
    package let audioBindingData: [Data]
    private let resources: [AnyObject]
    private let graphTextures: [String: MTLTexture]
    fileprivate init(texture: MTLTexture, size: RenderSize,
                     resources: [AnyObject], graphTextures: [String: MTLTexture],
                     audioBindingData: [Data]) {
        self.texture = texture
        self.size = size
        self.resources = resources
        self.graphTextures = graphTextures
        self.audioBindingData = audioBindingData
    }
    func graphTexture(_ name: String) -> MTLTexture? { graphTextures[name] }
}

private final class ComputeStorageRecord: @unchecked Sendable {
    let buffer: MTLBuffer
    private let lock = NSLock()
    private var initialized = false
    private weak var initializationCommand: MTLCommandBuffer?

    init(buffer: MTLBuffer) { self.buffer = buffer }

    func needsInitialization(in command: MTLCommandBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if initialized { return false }
        if let previous = initializationCommand {
            if previous === command { return false }
            if previous.status == .completed {
                initialized = true
                return false
            }
        }
        // An uncommitted command can be abandoned. Its fill never executed,
        // so the next encode must repeat it before reading this buffer.
        initializationCommand = command
        command.addCompletedHandler { [weak self] completed in
            guard let self else { return }
            self.lock.lock()
            if self.initializationCommand === completed {
                if completed.status == .completed { self.initialized = true }
                self.initializationCommand = nil
            }
            self.lock.unlock()
        }
        return true
    }
}

public final class NoisemakerRenderer {
    public let graph: RenderGraph
    public let size: RenderSize
    public let device: MTLDevice
    public let maximumTextureDimension2D: Int
    private let passes: [PreparedRenderPass]
    private let sampler: MTLSamplerState
    private let repeatSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
    private let mipSampler: MTLSamplerState?
    private let mipGenerator: MipGenerator?
    private let dummyTexture: MTLTexture
    private let bufferBridge: BufferToTextureBridge?
    private let texturePool: TexturePool
    private var feedbackState: FeedbackState?
    private var computeStorageBuffers: [String: ComputeStorageRecord] = [:]
    private var retired = false
    private var feedbackResampler: FeedbackResampler?
    let frameCoordinator = FrameCoordinator()

    func computeStorageBuffer(named name: String) -> MTLBuffer? {
        computeStorageBuffers[name]?.buffer
    }

    public init(device: MTLDevice, graph: RenderGraph, size: RenderSize,
                defaultVertexWGSL: String, vertexEntryPoint: String = "vs_main",
                registry: EffectRegistry? = nil,
                maximumTextureDimension2D: Int? = nil) throws {
        let deviceLimit = try TextureCapabilities.maximum2DDimension(for: device)
        let limit = maximumTextureDimension2D ?? deviceLimit
        guard (256...deviceLimit).contains(limit), size.width <= limit, size.height <= limit else {
            throw GraphDiagnostic.invalid("texture capability profile exceeds device or render dimensions")
        }
        let effectRegistry = try registry ?? EffectRegistry.bundled()
        var graph = try graph.clampingVolumeSizes(maximumTextureDimension2D: limit, registry: effectRegistry)
        let bundledVertex = try? EffectRegistry.bundled().defaultVertex
        let sourceHash = SHA256.hash(data: Data(defaultVertexWGSL.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let knownFullScreenVertex = vertexEntryPoint == "vs_main" &&
            sourceHash == "bf7099594c33843d1d7cb7947a6baec6a7154672d0aee386af8411022e39b4da" &&
            defaultVertexWGSL == bundledVertex?.field("wgsl")?.stringValue &&
            vertexEntryPoint == bundledVertex?.field("entryPoint")?.stringValue
        graph = graph.omittingProvenFullOverwrites(knownFullScreenVertex: knownFullScreenVertex)
        self.maximumTextureDimension2D = limit
        self.device = device
        self.graph = graph
        self.size = size
        self.texturePool = TexturePool(device: device)
        try graph.validateDimensions(for: size, maximumTextureDimension2D: limit)
        let displayOutput = "global_\(graph.renderSurface)"
        let displayNeedsHistory = graph.passes.contains { pass in
            guard pass.outputs.contains(where: { $0.value.stringValue == displayOutput }) else {
                return false
            }
            guard knownFullScreenVertex, let program = graph.programs[pass.program] else {
                return true
            }
            return !ShaderCompiler.provesFullOverwrite(pass: pass, program: program)
        }
        let usesFeedback = graph.passes.contains { pass in
            pass.repeatCount > 1 || pass.inputs.contains(where: {
                guard let name = $0.value.stringValue else { return false }
                return name.hasPrefix("global_") &&
                    !graph.externalTextureNames.contains(name)
            }) || pass.outputs.contains(where: {
                guard let name = $0.value.stringValue else { return false }
                return name.hasPrefix("global_") && name != "global_\(graph.renderSurface)"
            })
        } || displayNeedsHistory || graph.programs.values.contains(where: { $0.stage == .compute }) ||
            !graph.persistentTextureNames.isEmpty || graph.textures.contains(where: {
            $0.key == "global_\(graph.renderSurface)"
        })
        self.feedbackState = usesFeedback
            ? try FeedbackState(device: device, graph: graph, size: size) : nil
        let dummyDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        dummyDescriptor.storageMode = .shared
        dummyDescriptor.usage = .shaderRead
        guard let dummy = device.makeTexture(descriptor: dummyDescriptor) else {
            throw GraphDiagnostic.missing("Metal transparent dummy texture")
        }
        let zero = [UInt8](repeating: 0, count: 4)
        zero.withUnsafeBytes { bytes in
            dummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: 4)
        }
        self.dummyTexture = dummy
        let translator = ShaderTranslator()
        let vertexTranslation = try translator.translate(wgsl: defaultVertexWGSL,
            entryPoint: vertexEntryPoint, stage: .vertex)
        let vertex = try MetalVariantCache.shared.function(device: device,
            source: vertexTranslation.source, name: vertexTranslation.mslEntryPoint)
        let preparedPasses = try graph.passes.map { pass in
            guard let program = graph.programs[pass.program] else {
                throw GraphDiagnostic.missing("program \(pass.program)")
            }
            let formats = try pass.outputs.map { output -> MTLPixelFormat in
                guard let name = output.value.stringValue else {
                    throw GraphDiagnostic.invalid("pass \(pass.id) has non-string output")
                }
                if name.hasPrefix("global_") {
                    let format = graph.textures.first(where: { $0.key == name })?.format ?? "rgba16f"
                    return try Self.pixelFormat(format)
                }
                guard let texture = graph.textures.first(where: { $0.key == name }) else {
                    throw GraphDiagnostic.missing("pass \(pass.id) output texture \(name)")
                }
                return try Self.pixelFormat(texture.format)
            }
            return try ShaderCompiler.prepare(pass: pass, program: program,
                vertex: vertex, device: device, translator: translator,
                pixelFormats: formats,
                colorUniforms: try Self.colorUniformNames(pass: pass, registry: effectRegistry))
        }
        self.passes = preparedPasses
        self.bufferBridge = preparedPasses.contains(where: { prepared in
            prepared.resources.contains(where: { $0.kind == .storage })
        })
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
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        guard let linearSampler = device.makeSamplerState(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("Metal linear sampler")
        }
        self.linearSampler = linearSampler
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        guard let repeatSampler = device.makeSamplerState(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("Metal repeat sampler")
        }
        self.repeatSampler = repeatSampler
        let mipTextures = graph.textures.filter(\.mipmaps)
        let usesAuthoredMips = graph.passes.contains { pass in
            pass.raw.field("samplerTypes")?.objectFields?.contains {
                $0.value.stringValue == "mipmap"
            } == true
        }
        if mipTextures.isEmpty && !usesAuthoredMips {
            self.mipSampler = nil
            self.mipGenerator = nil
        } else {
            let mipDescriptor = MTLSamplerDescriptor()
            mipDescriptor.minFilter = .linear
            mipDescriptor.magFilter = .linear
            mipDescriptor.mipFilter = .linear
            mipDescriptor.sAddressMode = .clampToEdge
            mipDescriptor.tAddressMode = .clampToEdge
            guard let mipSampler = device.makeSamplerState(descriptor: mipDescriptor) else {
                throw GraphDiagnostic.missing("Metal mipmapped sampler")
            }
            self.mipSampler = mipSampler
            self.mipGenerator = mipTextures.isEmpty ? nil : try MipGenerator(device: device,
                formats: Set(try mipTextures.map { try Self.pixelFormat($0.format).rawValue }))
        }
    }

    /// Encodes one graph frame into a borrowed, uncommitted command buffer.
    /// Every call allocates a separate output so a retained lease cannot be overwritten.
    public func encode(frame: FrameState = .zero, into commandBuffer: MTLCommandBuffer,
                       externalTextures: [String: MTLTexture] = [:]) throws -> OutputLease {
        guard !retired else { throw GraphDiagnostic.invalid("renderer was retired after state transfer") }
        guard commandBuffer.device === device else {
            throw GraphDiagnostic.invalid("command buffer belongs to another Metal device")
        }
        guard commandBuffer.status == .notEnqueued else {
            throw GraphDiagnostic.invalid("command buffer must be uncommitted")
        }
        guard frame.time.isFinite, frame.delta.isFinite else {
            throw GraphDiagnostic.invalid("frame time and delta must be finite")
        }
        var frameTextures = externalTextures
        if graph.externalTextureNames.contains("midiNoteGrid"),
           frameTextures["midiNoteGrid"] == nil {
            frameTextures["midiNoteGrid"] = try MIDIGrid.texture(device: device,
                snapshot: frame.inputs.midi)
        }
        try validateExternalTextures(frameTextures)
        try frameCoordinator.beginEncode(commandBuffer)
        var succeeded = false
        var feedbackBegan = false
        var audioBindingData: [Data] = []
        var retained: [AnyObject] = [sampler, linearSampler, repeatSampler, dummyTexture]
        if let mipSampler { retained.append(mipSampler) }
        if let mipGenerator { retained.append(mipGenerator) }
        retained.append(contentsOf: frameTextures.values.map { $0 as AnyObject })
        retained.append(contentsOf: passes.map { $0.pipeline.retainedObject })
        if let bufferBridge { retained.append(bufferBridge) }
        var surfaceFrame: SurfaceManager?
        defer {
            if !succeeded {
                // A caller may still commit the partially encoded borrowed buffer.
                FrameCoordinator.keepAlive(retained, through: commandBuffer)
                if feedbackBegan { feedbackState?.abort(commandBuffer) }
                computeStorageBuffers.removeAll()
                frameCoordinator.discard(commandBuffer)
            }
        }
        var targets: [String: MTLTexture] = [:]
        var freshTargets: [MTLTexture] = []
        var initialMipTargets: [MTLTexture] = []
        let parameters = graph.dimensionParameters
        for texture in graph.textures where !texture.key.hasPrefix("global_") &&
            !graph.persistentTextureNames.contains(texture.key) &&
            !graph.externalTextureNames.contains(texture.key) &&
            frameTextures[texture.key] == nil {
            let lease = try makeTexture(named: texture.key, spec: texture, parameters: parameters)
            let target = lease.texture
            targets[texture.key] = target
            retained.append(lease)
            freshTargets.append(target)
        }
        targets.merge(frameTextures) { _, supplied in supplied }
        let outputName = "global_\(graph.renderSurface)"
        if let feedbackState {
            let (frame, needsClear) = try feedbackState.begin(commandBuffer)
            feedbackBegan = true
            surfaceFrame = frame
            targets.merge(feedbackState.targets) { _, new in new }
            retained.append(contentsOf: feedbackState.targets.values.map { $0 as AnyObject })
            for target in needsClear {
                try clear(target, command: commandBuffer, retained: &retained)
                if target.mipmapLevelCount > 1 { initialMipTargets.append(target) }
            }
            for copy in feedbackState.pendingCopies {
                guard let feedbackResampler else { throw GraphDiagnostic.missing("feedback resampler") }
                try feedbackResampler.encode(source: copy.source, target: copy.target, into: commandBuffer)
                retained.append(copy.source)
                if copy.target.mipmapLevelCount > 1 { initialMipTargets.append(copy.target) }
            }
        } else {
            guard targets[outputName] == nil else {
                throw GraphDiagnostic.invalid("render surface collides with graph texture")
            }
            let lease = try makeTexture(named: outputName, spec: nil, parameters: parameters)
            let output = lease.texture
            targets[outputName] = output
            retained.append(lease)
            freshTargets.append(output)
        }
        // WebGPU textures are zero-initialized. Metal's private allocations do
        // not promise that; clear once so an authored load observes the same data.
        for target in freshTargets {
            try clear(target, command: commandBuffer, retained: &retained)
        }
        if let mipGenerator {
            for target in initialMipTargets {
                try mipGenerator.encode(texture: target, into: commandBuffer, retained: &retained)
            }
        }
        for prepared in passes {
            let pass = prepared.graphPass
            if pass.conditions?.shouldSkip(pass: pass, frame: frame) == true { continue }
            for _ in 0..<pass.repeatCount {
                let resolved = try passTargets(pass, targets: targets, surfaces: surfaceFrame)
                switch prepared.pipeline {
                case .render(let pipeline):
                    try encodeRender(prepared, pipeline: pipeline, targets: resolved,
                        frame: frame, command: commandBuffer, retained: &retained,
                        audioBindingData: &audioBindingData)
                case .compute(let pipeline):
                    try encodeCompute(prepared, pipeline: pipeline, targets: resolved,
                        frame: frame, command: commandBuffer, retained: &retained,
                        audioBindingData: &audioBindingData)
                }
                try surfaceFrame?.advance(outputs: pass.outputs.compactMap { $0.value.stringValue },
                    repeated: pass.repeatCount > 1)
            }
        }
        if let mipGenerator {
            for spec in graph.textures where spec.mipmaps {
                guard let texture = targets[spec.key] else {
                    throw GraphDiagnostic.missing("mipmapped graph texture \(spec.key)")
                }
                try mipGenerator.encode(texture: texture, into: commandBuffer,
                    retained: &retained)
            }
        }
        let output: MTLTexture
        if var surfaceFrame, let feedbackState {
            let physical = try surfaceFrame.readTarget(outputName)
            guard let surfaceOutput = targets[physical] else {
                throw GraphDiagnostic.missing("final global surface \(physical)")
            }
            let lease = try snapshot(surfaceOutput, command: commandBuffer)
            output = lease.texture
            retained.append(lease)
            for name in graph.globalSurfaceNames {
                let physical = try surfaceFrame.readTarget("global_\(name)")
                targets["global_\(name)"] = targets[physical]
            }
            try surfaceFrame.finishFrame()
            feedbackState.accept(surfaceFrame, command: commandBuffer)
        } else {
            guard let simpleOutput = targets[outputName] else {
                throw GraphDiagnostic.missing("final render surface \(outputName)")
            }
            output = simpleOutput
        }
        FrameCoordinator.keepAlive(retained, through: commandBuffer)
        succeeded = true
        return OutputLease(texture: output, size: size,
            resources: retained, graphTextures: targets,
            audioBindingData: audioBindingData)
    }

    /// Replaces feedback textures after a failed GPU frame or an abandoned partial encode.
    /// The renderer's caller must serialize this with encode and wait for any accepted frame.
    public func resetFeedback() throws {
        guard !retired else { throw GraphDiagnostic.invalid("renderer was retired after state transfer") }
        guard let current = feedbackState else {
            computeStorageBuffers.removeAll()
            return
        }
        try current.requireIdle()
        feedbackState = try FeedbackState(device: device, graph: graph, size: size)
        computeStorageBuffers.removeAll()
    }

    /// Moves completed feedback into a prepared replacement. Call on the same
    /// serial executor as encode. A successful transfer retires the old renderer;
    /// any failure leaves both renderers unchanged.
    public func adoptFeedback(from previous: NoisemakerRenderer) throws {
        guard previous !== self, !retired, !previous.retired, device === previous.device else {
            throw GraphDiagnostic.invalid("feedback transfer requires distinct active renderers on one device")
        }
        try frameCoordinator.requireIdle()
        try previous.frameCoordinator.requireIdle()
        let transferred: FeedbackState?
        var resampler: FeedbackResampler?
        switch (previous.feedbackState, feedbackState) {
        case (nil, nil): transferred = nil
        case (let old?, let replacement?):
            try replacement.requireIdle()
            let persistent = Set(previous.graph.textures.filter { $0.raw.field("persistent")?.boolValue == true }
                .flatMap { texture in
                    texture.key.hasPrefix("global_")
                        ? ["\(texture.key)_read", "\(texture.key)_write"] : [texture.key]
                })
            transferred = try old.transferred(to: replacement, persistentNames: persistent)
            if let copies = transferred?.pendingCopies, !copies.isEmpty {
                resampler = try FeedbackResampler(device: device, formats: Set(copies.map { $0.target.pixelFormat.rawValue }))
            }
        default:
            throw GraphDiagnostic.unsupported("feedback topology changed during parameter update")
        }
        feedbackState = transferred
        feedbackResampler = resampler
        if size == previous.size {
            let bindings = Set(passes.flatMap { prepared in
                prepared.resources.filter { $0.kind == .storage }.map(\.name)
            })
            computeStorageBuffers = previous.computeStorageBuffers.filter {
                bindings.contains($0.key)
            }
        } else {
            computeStorageBuffers.removeAll()
        }
        previous.feedbackState = nil
        previous.computeStorageBuffers.removeAll()
        previous.retired = true
    }

    private struct PassTargets {
        let inputs: [String: MTLTexture]
        let outputs: [MTLTexture]
        let storageOutputs: [String: MTLTexture]
    }

    private func passTargets(_ pass: GraphPass, targets: [String: MTLTexture],
                             surfaces: SurfaceManager?) throws -> PassTargets {
        var inputs: [String: MTLTexture] = [:]
        for input in pass.inputs {
            guard let logical = input.value.stringValue else {
                throw GraphDiagnostic.invalid("pass \(pass.id) input \(input.key)")
            }
            if logical == "none" {
                inputs[input.key] = dummyTexture
            } else {
                let physical = graph.externalTextureNames.contains(logical)
                    ? logical : (try surfaces?.readTarget(logical) ?? logical)
                guard let target = targets[physical] else {
                    throw GraphDiagnostic.missing("pass \(pass.id) input texture \(physical)")
                }
                inputs[input.key] = target
            }
        }
        let outputs = try pass.outputs.map { output -> MTLTexture in
            guard let logical = output.value.stringValue else {
                throw GraphDiagnostic.invalid("pass \(pass.id) output \(output.key)")
            }
            let physical = try surfaces?.writeTarget(logical) ?? logical
            guard let target = targets[physical] else {
                throw GraphDiagnostic.missing("pass \(pass.id) output texture \(physical)")
            }
            return target
        }
        var storageOutputs: [String: MTLTexture] = [:]
        for output in pass.raw.field("storageTextures")?.objectFields ?? [] {
            guard let logical = output.value.stringValue,
                  let target = targets[logical], target.textureType == .type3D,
                  target.usage.contains(.shaderWrite) else {
                throw GraphDiagnostic.missing("pass \(pass.id) writable 3D texture \(output.name)")
            }
            storageOutputs[output.name] = target
        }
        return PassTargets(inputs: inputs, outputs: outputs, storageOutputs: storageOutputs)
    }

    private func clear(_ target: MTLTexture, command: MTLCommandBuffer,
                       retained: inout [AnyObject]) throws {
        if target.textureType == .type3D {
            // Source WebGPU allocations start at zero. Metal private 3D textures
            // have no render attachment, so initialize every depth slice by blit.
            let bytesPerPixel: Int
            switch target.pixelFormat {
            case .rgba8Unorm: bytesPerPixel = 4
            case .rgba16Float: bytesPerPixel = 8
            case .rgba32Float: bytesPerPixel = 16
            case .r8Unorm: bytesPerPixel = 1
            case .r16Float: bytesPerPixel = 2
            case .r32Float: bytesPerPixel = 4
            default: throw GraphDiagnostic.unsupported("3D clear pixel format")
            }
            let (rowPixels, rowOverflow) = target.width.multipliedReportingOverflow(by: bytesPerPixel)
            let (paddedRow, padOverflow) = rowPixels.addingReportingOverflow(255)
            guard !rowOverflow, !padOverflow else { throw GraphDiagnostic.unsupported("3D clear size overflow") }
            let rowBytes = paddedRow & ~255
            let (imageBytes, imageOverflow) = rowBytes.multipliedReportingOverflow(by: target.height)
            let (totalBytes, totalOverflow) = imageBytes.multipliedReportingOverflow(by: target.depth)
            guard !imageOverflow, !totalOverflow, totalBytes <= device.maxBufferLength,
                  let zero = device.makeBuffer(length: totalBytes, options: .storageModePrivate) else {
                throw GraphDiagnostic.unsupported("3D clear exceeds device buffer limit")
            }
            retained.append(zero)
            guard let blit = command.makeBlitCommandEncoder() else {
                throw GraphDiagnostic.missing("Metal 3D clear encoder")
            }
            blit.__fill(zero, range: NSRange(location: 0, length: totalBytes), value: 0)
            blit.copy(from: zero, sourceOffset: 0, sourceBytesPerRow: rowBytes,
                sourceBytesPerImage: imageBytes,
                sourceSize: MTLSize(width: target.width, height: target.height, depth: target.depth),
                to: target, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            return
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("Metal initial surface clear")
        }
        encoder.endEncoding()
    }

    private func snapshot(_ source: MTLTexture, command: MTLCommandBuffer) throws -> TextureLease {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
            width: source.width, height: source.height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .renderTarget]
        let lease = try texturePool.checkout(descriptor: descriptor)
        let output = lease.texture
        guard let encoder = command.makeBlitCommandEncoder() else {
            throw GraphDiagnostic.missing("Metal feedback output snapshot")
        }
        encoder.copy(from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: output, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.endEncoding()
        return lease
    }

    private func uniformBuffer(_ resource: ShaderResource, pass: GraphPass,
                               frame: FrameState, colorUniforms: Set<String>,
                               retained: inout [AnyObject],
                               audioBindingData: inout [Data]) throws -> MTLBuffer {
        guard let plan = resource.uniformPlan else {
            throw GraphDiagnostic.missing("pass \(pass.id) uniform plan \(resource.name)")
        }
        let data = try plan.encode(name: resource.name, pass: pass, frame: frame,
            size: size, colorUniforms: colorUniforms)
        if resource.name == "audioWaveform" || resource.name == "audioSpectrum" {
            guard data.count == 512 else {
                throw GraphDiagnostic.invalid("audio uniform binding must be 512 bytes")
            }
            audioBindingData.append(data)
        }
        guard let buffer = data.withUnsafeBytes({ bytes in
            bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: data.count,
                options: .storageModeShared) }
        }) else { throw GraphDiagnostic.missing("Metal uniform buffer for \(pass.id)") }
        retained.append(buffer)
        return buffer
    }

    private func inputTexture(_ resource: ShaderResource, pass: GraphPass,
                              targets: PassTargets) throws -> MTLTexture {
        // The source backend binds a transparent 1x1 view for a shader
        // declaration that has no pass input. passTargets has already rejected
        // any declared input whose texture cannot be resolved.
        if let texture = targets.inputs[resource.name] {
            guard texture.textureType == (resource.is3DTexture ? .type3D : .type2D) else {
                throw GraphDiagnostic.invalid("pass \(pass.id) input \(resource.name) texture dimension")
            }
            return texture
        }
        if resource.is3DTexture {
            throw GraphDiagnostic.missing("pass \(pass.id) 3D input \(resource.name)")
        }
        return dummyTexture
    }

    private func samplerState(_ resource: ShaderResource, pass: GraphPass) -> MTLSamplerState {
        let usesMips = pass.inputs.contains { input in
            guard let name = input.value.stringValue else { return false }
            return graph.textures.contains { $0.key == name && $0.mipmaps }
        }
        let sampledName = pass.inputs.first {
            $0.key == resource.sampledTextureName
        }?.value.stringValue
        let sampledVolume = graph.textures.first {
            $0.key == sampledName && $0.is3D
        }
        let usesExternal = pass.inputs.contains { input in
            guard let name = input.value.stringValue else { return false }
            // WebGPU uploadDataTexture creates MIDI's RGBA32F grid without
            // isExternal; only media/image uploads select the linear default.
            return name != "midiNoteGrid" && graph.externalTextureNames.contains(name)
        }
        switch pass.raw.field("samplerTypes")?.field(resource.name)?.stringValue {
        case "default": return linearSampler
        case "nearest": return sampler
        case "repeat": return repeatSampler
        case "mipmap": return mipSampler ?? linearSampler
        default:
            if let sampledVolume {
                return sampledVolume.filter == "nearest" ? sampler : linearSampler
            }
            return usesExternal ? linearSampler
                : (usesMips ? (mipSampler ?? linearSampler) : sampler)
        }
    }

    private func encodeRender(_ prepared: PreparedRenderPass, pipeline: MTLRenderPipelineState,
                              targets: PassTargets, frame: FrameState,
                              command: MTLCommandBuffer, retained: inout [AnyObject],
                              audioBindingData: inout [Data]) throws {
        let pass = prepared.graphPass
        let attachments = targets.outputs
        guard let first = attachments.first,
              attachments.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            throw GraphDiagnostic.unsupported("pass \(pass.id) MRT attachments have different dimensions")
        }
        let descriptor = MTLRenderPassDescriptor()
        for (index, target) in attachments.enumerated() {
            descriptor.colorAttachments[index].texture = target
            if case .bool(true) = pass.raw.field("clear") {
                descriptor.colorAttachments[index].loadAction = .clear
            } else {
                descriptor.colorAttachments[index].loadAction = .load
            }
            descriptor.colorAttachments[index].storeAction = .store
            descriptor.colorAttachments[index].clearColor = MTLClearColorMake(0, 0, 0, 0)
        }
        if prepared.depthStencil != nil {
            let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: first.width, height: first.height,
                mipmapped: false)
            depthDescriptor.storageMode = .private
            depthDescriptor.usage = .renderTarget
            let depth = try texturePool.checkout(descriptor: depthDescriptor)
            retained.append(depth)
            descriptor.depthAttachment.texture = depth.texture
            descriptor.depthAttachment.loadAction = .clear
            descriptor.depthAttachment.storeAction = .store
            descriptor.depthAttachment.clearDepth = 1
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("Metal render encoder for \(pass.id)")
        }
        encoder.label = pass.id
        encoder.setRenderPipelineState(pipeline)
        if let depth = prepared.depthStencil {
            encoder.setDepthStencilState(depth)
            encoder.setCullMode(.back)
            encoder.setFrontFacing(.clockwise)
            retained.append(depth)
        }
        do {
            for resource in prepared.resources {
                switch resource.kind {
                case .uniform:
                    let buffer = try uniformBuffer(resource, pass: pass, frame: frame,
                        colorUniforms: prepared.colorUniforms, retained: &retained,
                        audioBindingData: &audioBindingData)
                    encoder.setFragmentBuffer(buffer, offset: 0, index: resource.slot)
                    if prepared.customVertex {
                        encoder.setVertexBuffer(buffer, offset: 0, index: resource.slot)
                    }
                case .texture:
                    let texture = try inputTexture(resource, pass: pass, targets: targets)
                    encoder.setFragmentTexture(texture, index: resource.slot)
                    if prepared.customVertex {
                        encoder.setVertexTexture(texture, index: resource.slot)
                    }
                case .sampler:
                    let selected = samplerState(resource, pass: pass)
                    encoder.setFragmentSamplerState(selected, index: resource.slot)
                    if prepared.customVertex {
                        encoder.setVertexSamplerState(selected, index: resource.slot)
                    }
                default:
                    throw GraphDiagnostic.unsupported("pass \(pass.id) render binding \(resource.name)")
                }
            }
            let (primitive, count) = try drawPlan(pass: pass, targets: targets)
            encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: count)
            encoder.endEncoding()
        } catch {
            encoder.endEncoding()
            throw error
        }
    }

    private func drawPlan(pass: GraphPass, targets: PassTargets) throws
        -> (MTLPrimitiveType, Int) {
        let mode = pass.raw.field("drawMode")?.stringValue
        guard let mode else { return (.triangle, 3) }
        let count = pass.raw.field("count")
        var resolved: Int
        if let literal = count?.numberValue, literal > 0 {
            resolved = Int(literal)
        } else if mode == "triangles" {
            resolved = 3
        } else {
            resolved = 1_000
        }
        let requested = count?.stringValue
        if mode != "triangles", (requested == "auto" || requested == "screen") {
            guard let output = targets.outputs.first else {
                throw GraphDiagnostic.missing("pass \(pass.id) draw output")
            }
            resolved = output.width * output.height
        } else if requested == "input" ||
                    (mode == "triangles" && (requested == "auto" || count?.numberValue == 0)) {
            let preferred = mode == "triangles"
                ? ["meshPositions", "inputTex"] : ["xyzTex", "inputTex"]
            if let texture = preferred.compactMap({ targets.inputs[$0] }).first {
                resolved = texture.width * texture.height
            } else if mode == "triangles" {
                resolved = 3
            } else {
                resolved = size.width * size.height
            }
        }
        if mode == "triangles",
           let countName = pass.raw.field("countUniform")?.stringValue,
           let number = pass.uniforms.first(where: { $0.name == countName })?.value.numberValue,
           number.isFinite, number > 0, number <= 16_000_000 {
            resolved = Int(number)
        }
        if mode == "billboards" {
            guard resolved <= 16_000_000 / 6 else {
                throw GraphDiagnostic.unsupported("pass \(pass.id) billboard count exceeds bound")
            }
            resolved *= 6
        }
        guard (0...16_000_000).contains(resolved) else {
            throw GraphDiagnostic.unsupported("pass \(pass.id) draw count exceeds bound")
        }
        return (mode == "points" ? .point : .triangle, resolved)
    }

    private func encodeCompute(_ prepared: PreparedRenderPass, pipeline: MTLComputePipelineState,
                               targets: PassTargets, frame: FrameState,
                               command: MTLCommandBuffer, retained: inout [AnyObject],
                               audioBindingData: inout [Data]) throws {
        let pass = prepared.graphPass
        if prepared.resources.contains(where: { $0.kind == .storageTexture }) {
            try encodeStorageTextureCompute(prepared, pipeline: pipeline, targets: targets,
                frame: frame, command: command, retained: &retained,
                audioBindingData: &audioBindingData)
            return
        }
        guard let target = targets.outputs.first, let bridge = bufferBridge else {
            throw GraphDiagnostic.missing("pass \(pass.id) compute output or conversion pipeline")
        }
        guard target.width == size.width, target.height == size.height else {
            throw GraphDiagnostic.unsupported("pass \(pass.id) compute output must be screen-sized for upstream buffer indexing")
        }
        let (pixels, pixelOverflow) = target.width.multipliedReportingOverflow(by: target.height)
        let (requiredBytes, byteOverflow) = pixels.multipliedReportingOverflow(
            by: 4 * MemoryLayout<Float>.size)
        let (roundedBytes, roundOverflow) = requiredBytes.addingReportingOverflow(255)
        guard !pixelOverflow, !byteOverflow, !roundOverflow, requiredBytes > 0,
              roundedBytes <= Int(UInt32.max) else {
            throw GraphDiagnostic.unsupported("pass \(pass.id) output storage buffer size")
        }
        let byteCount = roundedBytes & ~255
        guard let bufferName = prepared.resources.first(where: { $0.kind == .storage })?.name else {
            throw GraphDiagnostic.missing("pass \(pass.id) output storage buffer binding")
        }
        let record: ComputeStorageRecord
        if let existing = computeStorageBuffers[bufferName] {
            guard existing.buffer.length == byteCount else {
                throw GraphDiagnostic.unsupported("pass \(pass.id) output storage buffer changed size")
            }
            record = existing
        } else if let created = device.makeBuffer(length: byteCount, options: .storageModePrivate) {
            record = ComputeStorageRecord(buffer: created)
            computeStorageBuffers[bufferName] = record
        } else {
            throw GraphDiagnostic.missing("pass \(pass.id) output storage buffer")
        }
        let storage = record.buffer
        retained.append(storage)
        if record.needsInitialization(in: command) {
            guard let zero = command.makeBlitCommandEncoder() else {
                throw GraphDiagnostic.missing("pass \(pass.id) storage initialization encoder")
            }
            zero.__fill(storage, range: NSRange(location: 0, length: byteCount), value: 0)
            zero.endEncoding()
        }
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GraphDiagnostic.missing("Metal compute encoder for \(pass.id)")
        }
        encoder.label = pass.id
        encoder.setComputePipelineState(pipeline)
        do {
            for resource in prepared.resources {
                switch resource.kind {
                case .uniform:
                    let buffer = try uniformBuffer(resource, pass: pass, frame: frame,
                        colorUniforms: prepared.colorUniforms, retained: &retained,
                        audioBindingData: &audioBindingData)
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

    private func encodeStorageTextureCompute(_ prepared: PreparedRenderPass,
                                             pipeline: MTLComputePipelineState,
                                             targets: PassTargets, frame: FrameState,
                                             command: MTLCommandBuffer,
                                             retained: inout [AnyObject],
                                             audioBindingData: inout [Data]) throws {
        let pass = prepared.graphPass
        guard let counts = pass.raw.field("workgroups")?.arrayValue,
              counts.count == 3,
              let gx = counts[0].numberValue, let gy = counts[1].numberValue,
              let gz = counts[2].numberValue else {
            throw GraphDiagnostic.invalid("pass \(pass.id) 3D compute workgroups")
        }
        let (x, y, z) = prepared.workgroupSize
        let caps = device.maxThreadsPerThreadgroup
        guard x > 0, y > 0, z > 0,
              UInt64(x) <= UInt64(caps.width), UInt64(y) <= UInt64(caps.height),
              UInt64(z) <= UInt64(caps.depth),
              UInt64(x) * UInt64(y) * UInt64(z) <= UInt64(pipeline.maxTotalThreadsPerThreadgroup) else {
            throw GraphDiagnostic.unsupported("pass \(pass.id) workgroup size exceeds Metal capability")
        }
        let threads = MTLSize(width: Int(x), height: Int(y), depth: Int(z))
        let groups = MTLSize(width: Int(gx), height: Int(gy), depth: Int(gz))
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GraphDiagnostic.missing("Metal 3D compute encoder for \(pass.id)")
        }
        encoder.label = pass.id
        encoder.setComputePipelineState(pipeline)
        do {
            for resource in prepared.resources {
                switch resource.kind {
                case .uniform:
                    let buffer = try uniformBuffer(resource, pass: pass, frame: frame,
                        colorUniforms: prepared.colorUniforms, retained: &retained,
                        audioBindingData: &audioBindingData)
                    encoder.setBuffer(buffer, offset: 0, index: resource.slot)
                case .texture:
                    encoder.setTexture(try inputTexture(resource, pass: pass, targets: targets),
                        index: resource.slot)
                case .storageTexture:
                    guard let target = targets.storageOutputs[resource.name] else {
                        throw GraphDiagnostic.missing("pass \(pass.id) 3D storage binding \(resource.name)")
                    }
                    encoder.setTexture(target, index: resource.slot)
                case .sampler:
                    encoder.setSamplerState(samplerState(resource, pass: pass),
                        index: resource.slot)
                default:
                    throw GraphDiagnostic.unsupported("pass \(pass.id) 3D compute binding \(resource.name)")
                }
            }
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        } catch {
            encoder.endEncoding()
            throw error
        }
    }

    private static func pixelFormat(_ format: String) throws -> MTLPixelFormat {
        switch format {
        case "rgba16f", "rgba16float": return .rgba16Float
        case "rgba8", "rgba8unorm": return .rgba8Unorm
        case "rgba32f", "rgba32float": return .rgba32Float
        case "r8", "r8unorm": return .r8Unorm
        case "r16f", "r16float": return .r16Float
        case "r32f", "r32float": return .r32Float
        default: throw GraphDiagnostic.unsupported("texture format \(format)")
        }
    }

    private func validateExternalTextures(_ supplied: [String: MTLTexture]) throws {
        let required = Set(graph.externalTextureNames)
        // Source-allocated 3D volumes may be populated by a host upload before
        // rendering. Supplying one replaces only that named volume for this frame.
        let optionalVolumes = Set(graph.textures.filter(\.is3D).map(\.key))
        let writableVolumes = Set(graph.passes.flatMap { pass in
            pass.raw.field("storageTextures")?.objectFields?
                .compactMap { $0.value.stringValue } ?? []
        })
        let names = Set(supplied.keys)
        guard names.isDisjoint(with: writableVolumes) else {
            throw GraphDiagnostic.unsupported("internally written 3D textures cannot be externally replaced")
        }
        guard required.isSubset(of: names), names.isSubset(of: required.union(optionalVolumes)) else {
            throw GraphDiagnostic.missing("external textures \(graph.externalTextureNames)")
        }
        for name in names.sorted() {
            let spec = graph.textures.first(where: { $0.key == name })
            let is3D = spec?.is3D == true
            guard let texture = supplied[name], texture.device === device,
                  texture.textureType == (is3D ? .type3D : .type2D),
                  (is3D || texture.depth == 1), texture.sampleCount == 1,
                  texture.usage.contains(.shaderRead) || texture.usage == .unknown else {
                throw GraphDiagnostic.invalid("external texture \(name) device, shape, usage or format")
            }
            if graph.mediaSteps.contains(where: { $0.textureId == name }) {
                guard texture.width > 0, texture.height > 0,
                      [.rgba8Unorm, .bgra8Unorm].contains(texture.pixelFormat) else {
                    throw GraphDiagnostic.invalid("media texture \(name) dimensions or format")
                }
            } else if let spec {
                let expectedDepth = try spec.depth?.resolve(screen: size.width,
                    parameters: graph.dimensionParameters) ?? 1
                guard texture.width == (try spec.width.resolve(screen: size.width,
                          parameters: graph.dimensionParameters)),
                      texture.height == (try spec.height.resolve(screen: size.height,
                          parameters: graph.dimensionParameters)),
                      texture.depth == expectedDepth,
                      texture.pixelFormat == (try Self.pixelFormat(spec.format)) else {
                    throw GraphDiagnostic.invalid("external texture \(name) dimensions or format")
                }
            } else if name == "midiNoteGrid" {
                guard texture.width == MIDIGrid.width,
                      texture.height == MIDIGrid.height,
                      texture.pixelFormat == .rgba32Float else {
                    throw GraphDiagnostic.invalid("MIDI grid dimensions or format")
                }
            } else {
                guard texture.width > 0, texture.height > 0,
                      texture.pixelFormat == .rgba32Float else {
                    throw GraphDiagnostic.invalid("mesh texture \(name) dimensions or format")
                }
            }
        }
    }

    private static func colorUniformNames(pass: GraphPass,
                                          registry: EffectRegistry?) throws -> Set<String> {
        let hexNames = Set(pass.uniforms.compactMap { field in
            field.value.stringValue?.hasPrefix("#") == true ? field.name : nil
        })
        guard let key = pass.raw.field("effectKey")?.stringValue,
              let effect = registry?.effect(key: key),
              let globals = effect.definition.field("globals")?.objectFields else {
            if !hexNames.isEmpty {
                throw GraphDiagnostic.unsupported("pass \(pass.id) lacks typed color metadata")
            }
            return []
        }
        let typed = Set(globals.compactMap { field -> String? in
            guard field.value.field("type")?.stringValue == "color" else { return nil }
            return field.value.field("uniform")?.stringValue ?? field.name
        })
        guard hexNames.isSubset(of: typed) else {
            throw GraphDiagnostic.unsupported("pass \(pass.id) hex uniform is not typed as color")
        }
        return typed
    }

    private func makeTexture(named name: String, spec: GraphTexture?, parameters: [String: Double]) throws -> TextureLease {
        let width = try spec?.width.resolve(screen: size.width, parameters: parameters) ?? size.width
        let height = try spec?.height.resolve(screen: size.height, parameters: parameters) ?? size.height
        let format = try spec.map { try Self.pixelFormat($0.format) } ?? .rgba16Float
        let descriptor: MTLTextureDescriptor
        if spec?.is3D == true {
            guard let depth = try spec?.depth?.resolve(screen: size.width,
                parameters: parameters) else {
                throw GraphDiagnostic.missing("3D texture \(name) depth")
            }
            descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = format
            descriptor.width = width
            descriptor.height = height
            descriptor.depth = depth
            descriptor.mipmapLevelCount = 1
            descriptor.usage = [.shaderRead, .shaderWrite]
        } else {
            descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
        }
        descriptor.storageMode = .private
        let lease = try texturePool.checkout(descriptor: descriptor)
        let texture = lease.texture
        texture.label = name
        return lease
    }

}
