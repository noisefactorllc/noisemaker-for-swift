import Foundation
import MetalKit
import Noisemaker

public typealias ViewExternalTexturesProvider = (FrameState) throws -> [String: MTLTexture]

/// Optional main-actor MTKView integration. The core renderer has no view or UI dependency.
/// Keep this object alive while the view uses it as its weak delegate.
@MainActor
public final class NoisemakerViewRenderer: NSObject, MTKViewDelegate {
    public private(set) var renderer: NoisemakerRenderer
    public private(set) var frameIndex: UInt64 = 0
    public private(set) var lastError: (any Error)?
    public var onError: ((any Error) -> Void)?
    public var frameProvider: ((UInt64) -> FrameState)?
    /// Return already-prepared textures keyed by graph.externalTextureNames.
    public var externalTexturesProvider: ViewExternalTexturesProvider?
    private var externalTexturesPreparation:
        ((RenderGraph, RenderSize) throws -> ViewExternalTexturesProvider)?
    private var registry: EffectRegistry?
    private weak var view: MTKView?
    private let queue: MTLCommandQueue
    private let presenter: TexturePresenter
    private let vertexWGSL: String
    private let vertexEntryPoint: String
    var clock: FrameClock
    public var loopDuration: TimeInterval { clock.duration }
    private let completion = PresentationCompletion()

    public init(view: MTKView, graph: RenderGraph, defaultVertexWGSL: String,
                vertexEntryPoint: String = "vs_main", loopDuration: TimeInterval = 10,
                registry: EffectRegistry? = nil,
                maximumTextureDimension2D: Int? = nil) throws {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw GraphDiagnostic.missing("Metal view device or command queue")
        }
        self.registry = registry
        self.clock = try FrameClock(duration: loopDuration)
        let size = try Self.renderSize(view.drawableSize)
        renderer = try NoisemakerRenderer(device: device, graph: graph, size: size,
            defaultVertexWGSL: defaultVertexWGSL, vertexEntryPoint: vertexEntryPoint,
            registry: registry, maximumTextureDimension2D: maximumTextureDimension2D)
        self.queue = queue
        self.presenter = try TexturePresenter(device: device)
        self.vertexWGSL = defaultVertexWGSL
        self.vertexEntryPoint = vertexEntryPoint
        self.view = view
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = 1
        view.framebufferOnly = true
        view.delegate = self
    }

    /// Prepare before swapping. A compile/allocation failure preserves the active graph.
    public func replaceGraph(_ graph: RenderGraph, registry: EffectRegistry? = nil) throws {
        let prepared = try NoisemakerRenderer(device: renderer.device, graph: graph, size: renderer.size,
            defaultVertexWGSL: vertexWGSL, vertexEntryPoint: vertexEntryPoint,
            registry: registry ?? self.registry,
            maximumTextureDimension2D: renderer.maximumTextureDimension2D)
        let preparedInputs = try externalTexturesPreparation?(prepared.graph, renderer.size)
        self.registry = registry ?? self.registry
        renderer = prepared
        if let preparedInputs { externalTexturesProvider = preparedInputs }
        resetClock()
    }

    /// Prepare the new size and migrate completed feedback before publication.
    /// Existing output leases retain their old resources.
    public func resize(to size: RenderSize) throws {
        guard size != renderer.size else { return }
        let active = renderer
        let prepared = try NoisemakerRenderer(device: active.device, graph: active.graph, size: size,
            defaultVertexWGSL: vertexWGSL, vertexEntryPoint: vertexEntryPoint,
            registry: registry, maximumTextureDimension2D: active.maximumTextureDimension2D)
        let preparedInputs = try externalTexturesPreparation?(prepared.graph, size)
        try prepared.adoptFeedback(from: active)
        renderer = prepared
        if let preparedInputs { externalTexturesProvider = preparedInputs }
        lastError = nil
    }

    /// Installs a source of host-owned textures for the current graph and all
    /// future graph/size replacements. Preparation happens before publication.
    public func setExternalTexturesPreparation(
        _ prepare: @escaping (RenderGraph, RenderSize) throws -> ViewExternalTexturesProvider
    ) throws {
        let provider = try prepare(renderer.graph, renderer.size)
        externalTexturesPreparation = prepare
        externalTexturesProvider = provider
    }

    /// Updates only the selected effect instance. The source graph, Metal
    /// resources, and host textures are prepared before the active renderer is
    /// replaced. Live updates keep the presentation clock and frame index.
    public func updateParameter(stepIndex: Int, name: String, value: GraphValue) throws {
        let selectedRegistry = try registry ?? EffectRegistry.bundled()
        let active = renderer
        let graph = try active.graph.updatedParameter(stepIndex: stepIndex, name: name,
                                                      value: value, registry: selectedRegistry)
        if Self.sameValue(active.graph.raw, graph.raw) { return }
        guard graph.externalTextureNames.isEmpty || externalTexturesPreparation != nil else {
            throw GraphDiagnostic.unsupported(
                "live updates with external textures require setExternalTexturesPreparation")
        }
        let prepared = try NoisemakerRenderer(device: active.device, graph: graph, size: active.size,
            defaultVertexWGSL: vertexWGSL, vertexEntryPoint: vertexEntryPoint,
            registry: selectedRegistry,
            maximumTextureDimension2D: active.maximumTextureDimension2D)
        let preparedInputs = try externalTexturesPreparation?(prepared.graph, active.size)
        try prepared.adoptFeedback(from: active)
        renderer = prepared
        registry = selectedRegistry
        if let preparedInputs { externalTexturesProvider = preparedInputs }
        lastError = nil
    }

    public func reset() throws {
        try renderer.resetFeedback()
        resetClock()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Minimized and temporarily detached views may have no drawable area.
        guard size.width > 0, size.height > 0 else { return }
        do { try resize(to: Self.renderSize(size)) }
        catch { report(error) }
    }

    public func draw(in view: MTKView) {
        // Do not advance feedback/time when presentation has no available drawable.
        guard let drawable = view.currentDrawable else { return }
        guard completion.reserve() else { return }
        do {
            if let gpuError = completion.takeError() { throw gpuError }
            try resize(to: RenderSize(width: drawable.texture.width, height: drawable.texture.height))
            guard let command = queue.makeCommandBuffer() else {
                throw GraphDiagnostic.missing("view command buffer")
            }
            let now = ProcessInfo.processInfo.systemUptime
            var nextClock = clock
            let frame = frameProvider?(frameIndex) ?? nextClock.next(at: now, index: frameIndex)
            let inputs = try externalTexturesProvider?(frame) ?? [:]
            let output = try renderer.encode(frame: frame, into: command, externalTextures: inputs)
            try presenter.encode(source: output.texture, target: drawable.texture, into: command)
            command.present(drawable)
            completion.track(command)
            command.commit()
            clock = nextClock
            frameIndex += 1
            lastError = nil
        } catch {
            completion.finish(error: nil)
            report(error)
        }
    }

    private func resetClock() {
        frameIndex = 0
        clock.reset()
        lastError = nil
    }
    private func report(_ error: any Error) { lastError = error; onError?(error) }

    private static func sameValue(_ a: GraphValue, _ b: GraphValue) -> Bool {
        switch (a, b) {
        case (.undefined, .undefined), (.null, .null): return true
        case (.bool(let left), .bool(let right)): return left == right
        case (.number(let left), .number(let right)): return left.bitPattern == right.bitPattern
        case (.string(let left), .string(let right)): return left == right
        case (.array(let left), .array(let right)):
            return left.count == right.count && zip(left, right).allSatisfy { sameValue($0, $1) }
        case (.object(let left), .object(let right)):
            return left.count == right.count && zip(left, right).allSatisfy {
                $0.name == $1.name && sameValue($0.value, $1.value)
            }
        case (.map(let left), .map(let right)):
            return left.count == right.count && zip(left, right).allSatisfy {
                sameValue($0.key, $1.key) && sameValue($0.value, $1.value)
            }
        case (.tagged(let leftTag, let left), .tagged(let rightTag, let right)):
            return leftTag == rightTag && left.count == right.count &&
                zip(left, right).allSatisfy {
                    $0.name == $1.name && sameValue($0.value, $1.value)
                }
        default: return false
        }
    }

    private static func renderSize(_ size: CGSize) throws -> RenderSize {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, size.width < 32769, size.height < 32769 else {
            throw GraphDiagnostic.invalid("view drawable size is invalid")
        }
        return try RenderSize(width: Int(size.width), height: Int(size.height))
    }
}
private final class PresentationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var error: (any Error)?
    // Metal callbacks run on driver threads. Construct the callback outside the
    // main actor so older SDK block annotations cannot infer actor isolation.
    func track(_ command: MTLCommandBuffer) {
        command.addCompletedHandler { @Sendable [self] command in finish(error: command.error) }
    }
    func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !inFlight else { return false }
        inFlight = true
        return true
    }
    func finish(error: (any Error)?) {
        lock.lock(); defer { lock.unlock() }
        inFlight = false
        self.error = error
    }
    func takeError() -> (any Error)? {
        lock.lock(); defer { lock.unlock() }
        defer { error = nil }
        return error
    }
}

extension NoisemakerViewRenderer {
    /// Creates a view host using the package's source-bound default shader.
    public convenience init(view: MTKView, graph: RenderGraph, loopDuration: TimeInterval = 10,
                            registry: EffectRegistry? = nil,
                            maximumTextureDimension2D: Int? = nil) throws {
        let vertex = try BundledShaderSources.vertex()
        try self.init(view: view, graph: graph, defaultVertexWGSL: vertex.wgsl,
            vertexEntryPoint: vertex.entryPoint, loopDuration: loopDuration, registry: registry,
            maximumTextureDimension2D: maximumTextureDimension2D)
    }

    /// Compiles a DSL document and prepares the initial demo ProgramState values
    /// before any texture dimensions or Metal resources are validated.
    public convenience init(view: MTKView, source: String, loopDuration: TimeInterval = 10,
                            registry: EffectRegistry? = nil,
                            maximumTextureDimension2D: Int? = nil) throws {
        let selectedRegistry = try registry ?? EffectRegistry.bundled()
        let graph = try NoisemakerCompiler(registry: selectedRegistry).compileForHost(source: source)
        try self.init(view: view, graph: graph, loopDuration: loopDuration,
            registry: selectedRegistry, maximumTextureDimension2D: maximumTextureDimension2D)
    }
}
