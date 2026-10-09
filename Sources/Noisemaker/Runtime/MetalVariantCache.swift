import Foundation
import Metal

/// Bounded process-local reuse of exact MSL functions and Metal pipeline states.
/// Function identity is keyed by device, complete translated source, and entry
/// point. Pipeline entries retain their functions, so object identity cannot be
/// recycled while a cached pipeline is live.
final class MetalVariantCache: @unchecked Sendable {
    static let shared = MetalVariantCache(maxFunctions: 128, maxPipelines: 128,
                                          maxSourceBytes: 24 * 1024 * 1024)

    private struct FunctionKey: Hashable {
        let device: ObjectIdentifier
        let source: String
        let name: String
        let fastMath: Bool
    }
    private struct ColorState: Hashable {
        let format: UInt
        let writeMask: UInt
        let blending: Bool
        let rgbOperation: UInt
        let alphaOperation: UInt
        let sourceRGB: UInt
        let sourceAlpha: UInt
        let destinationRGB: UInt
        let destinationAlpha: UInt

        init(_ attachment: MTLRenderPipelineColorAttachmentDescriptor) {
            format = attachment.pixelFormat.rawValue
            writeMask = attachment.writeMask.rawValue
            blending = attachment.isBlendingEnabled
            rgbOperation = attachment.rgbBlendOperation.rawValue
            alphaOperation = attachment.alphaBlendOperation.rawValue
            sourceRGB = attachment.sourceRGBBlendFactor.rawValue
            sourceAlpha = attachment.sourceAlphaBlendFactor.rawValue
            destinationRGB = attachment.destinationRGBBlendFactor.rawValue
            destinationAlpha = attachment.destinationAlphaBlendFactor.rawValue
        }
    }
    private struct RenderKey: Hashable {
        let device: ObjectIdentifier
        let vertex: ObjectIdentifier
        let fragment: ObjectIdentifier
        let colors: [ColorState]
        let depthFormat: UInt
        let stencilFormat: UInt
        let topology: UInt
        let sampleCount: Int
        let depthCompare: UInt?
        let depthWrite: Bool
    }
    private struct ComputeKey: Hashable {
        let device: ObjectIdentifier
        let function: ObjectIdentifier
    }
    private struct FunctionEntry {
        let device: MTLDevice
        let function: MTLFunction
        let cost: Int
    }
    private struct RenderEntry {
        let device: MTLDevice
        let vertex: MTLFunction
        let fragment: MTLFunction
        let pipeline: MTLRenderPipelineState
    }
    private struct ComputeEntry {
        let device: MTLDevice
        let function: MTLFunction
        let pipeline: MTLComputePipelineState
    }

    private let lock = NSLock()
    private let maxFunctions: Int
    private let maxPipelines: Int
    private let maxSourceBytes: Int
    private var functions: [FunctionKey: FunctionEntry] = [:]
    private var functionOrder: [FunctionKey] = []
    private var sourceBytes = 0
    private var renders: [RenderKey: RenderEntry] = [:]
    private var renderOrder: [RenderKey] = []
    private var computes: [ComputeKey: ComputeEntry] = [:]
    private var computeOrder: [ComputeKey] = []
    private var functionHits = 0
    private var renderHits = 0
    private var computeHits = 0

    init(maxFunctions: Int, maxPipelines: Int, maxSourceBytes: Int) {
        self.maxFunctions = max(0, maxFunctions)
        self.maxPipelines = max(0, maxPipelines)
        self.maxSourceBytes = max(0, maxSourceBytes)
    }

    func function(device: MTLDevice, source: String, name: String) throws -> MTLFunction {
        let key = FunctionKey(device: ObjectIdentifier(device), source: source,
                              name: name, fastMath: MetalLibraryCache.fastMathEnabled)
        lock.lock(); defer { lock.unlock() }
        if let entry = functions[key] {
            functionHits += 1
            RuntimeBenchmarkProbe.active?.record("metalFunctionCacheHitCount")
            functionOrder.removeAll { $0 == key }
            functionOrder.append(key)
            return entry.function
        }
        let library = try MetalLibraryCache.library(device: device, source: source)
        guard let result = RuntimeBenchmarkProbe.measure("metalFunctionCreateMS", {
            library.makeFunction(name: name)
        }) else {
            throw GraphDiagnostic.missing("Metal function \(name) in translated source")
        }
        RuntimeBenchmarkProbe.active?.record("metalFunctionCreateCount")
        let cost = source.utf8.count + name.utf8.count
        guard maxFunctions > 0, cost <= maxSourceBytes else { return result }
        while !functionOrder.isEmpty &&
            (functions.count >= maxFunctions || sourceBytes + cost > maxSourceBytes) {
            let oldest = functionOrder.removeFirst()
            if let removed = functions.removeValue(forKey: oldest) { sourceBytes -= removed.cost }
        }
        functions[key] = FunctionEntry(device: device, function: result, cost: cost)
        functionOrder.append(key)
        sourceBytes += cost
        return result
    }

    /// All descriptor fields configured by ShaderCompiler are represented in
    /// this key. The descriptor is created fresh for each request, with Metal's
    /// defaults for fields that ShaderCompiler does not set.
    func renderPipeline(device: MTLDevice, descriptor: MTLRenderPipelineDescriptor,
                        depthCompare: MTLCompareFunction? = nil,
                        depthWrite: Bool = false) throws -> MTLRenderPipelineState {
        guard let vertex = descriptor.vertexFunction,
              let fragment = descriptor.fragmentFunction else {
            throw GraphDiagnostic.missing("render pipeline vertex or fragment function")
        }
        let key = RenderKey(device: ObjectIdentifier(device),
            vertex: ObjectIdentifier(vertex), fragment: ObjectIdentifier(fragment),
            colors: (0..<8).map { ColorState(descriptor.colorAttachments[$0]) },
            depthFormat: descriptor.depthAttachmentPixelFormat.rawValue,
            stencilFormat: descriptor.stencilAttachmentPixelFormat.rawValue,
            topology: descriptor.inputPrimitiveTopology.rawValue,
            sampleCount: descriptor.rasterSampleCount,
            depthCompare: depthCompare?.rawValue, depthWrite: depthWrite)
        lock.lock(); defer { lock.unlock() }
        if let entry = renders[key] {
            renderHits += 1
            RuntimeBenchmarkProbe.active?.record("metalRenderPipelineCacheHitCount")
            renderOrder.removeAll { $0 == key }
            renderOrder.append(key)
            return entry.pipeline
        }
        let pipeline = try RuntimeBenchmarkProbe.measure("metalRenderPipelineCompileMS") {
            try device.makeRenderPipelineState(descriptor: descriptor)
        }
        RuntimeBenchmarkProbe.active?.record("metalRenderPipelineCompileCount")
        guard maxPipelines > 0 else { return pipeline }
        while renders.count >= maxPipelines, !renderOrder.isEmpty {
            renders.removeValue(forKey: renderOrder.removeFirst())
        }
        renders[key] = RenderEntry(device: device, vertex: vertex,
                                   fragment: fragment, pipeline: pipeline)
        renderOrder.append(key)
        return pipeline
    }

    func computePipeline(device: MTLDevice, function: MTLFunction) throws -> MTLComputePipelineState {
        let key = ComputeKey(device: ObjectIdentifier(device), function: ObjectIdentifier(function))
        lock.lock(); defer { lock.unlock() }
        if let entry = computes[key] {
            computeHits += 1
            RuntimeBenchmarkProbe.active?.record("metalComputePipelineCacheHitCount")
            computeOrder.removeAll { $0 == key }
            computeOrder.append(key)
            return entry.pipeline
        }
        let pipeline = try RuntimeBenchmarkProbe.measure("metalComputePipelineCompileMS") {
            try device.makeComputePipelineState(function: function)
        }
        RuntimeBenchmarkProbe.active?.record("metalComputePipelineCompileCount")
        guard maxPipelines > 0 else { return pipeline }
        while computes.count >= maxPipelines, !computeOrder.isEmpty {
            computes.removeValue(forKey: computeOrder.removeFirst())
        }
        computes[key] = ComputeEntry(device: device, function: function, pipeline: pipeline)
        computeOrder.append(key)
        return pipeline
    }

    var snapshot: (functions: Int, renders: Int, computes: Int, sourceBytes: Int,
                   functionHits: Int, renderHits: Int, computeHits: Int) {
        lock.lock(); defer { lock.unlock() }
        return (functions.count, renders.count, computes.count, sourceBytes,
                functionHits, renderHits, computeHits)
    }
}
