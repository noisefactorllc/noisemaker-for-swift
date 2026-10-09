import Foundation
import Metal

/// Owns global surface halves and ordinary textures whose previous-frame
/// contents can be observed. Completion publishes a copied binding map only
/// after Metal succeeds; a failed frame requires fresh textures.
final class FeedbackState: @unchecked Sendable {
    let targets: [String: MTLTexture]
    private let lock = NSLock()
    private var bindings: SurfaceManager
    private weak var pending: MTLCommandBuffer?
    private var clearNames: Set<String>
    private(set) var pendingCopies: [(source: MTLTexture, target: MTLTexture)] = []
    private var failed = false

    init(device: MTLDevice, graph: RenderGraph, size: RenderSize) throws {
        let bindings = try SurfaceManager(surfaces: graph.globalSurfaceNames)
        var targets: [String: MTLTexture] = [:]
        for name in graph.globalSurfaceNames {
            let logical = "global_\(name)"
            let spec = graph.textures.first(where: { $0.key == logical })
            let width = try spec?.width.resolve(screen: size.width,
                parameters: graph.dimensionParameters) ?? size.width
            let height = try spec?.height.resolve(screen: size.height,
                parameters: graph.dimensionParameters) ?? size.height
            let format: MTLPixelFormat
            switch spec?.format ?? "rgba16f" {
            case "rgba16f", "rgba16float": format = .rgba16Float
            case "rgba8", "rgba8unorm": format = .rgba8Unorm
            case "rgba32f", "rgba32float": format = .rgba32Float
            case "r8", "r8unorm": format = .r8Unorm
            case "r16f", "r16float": format = .r16Float
            case "r32f", "r32float": format = .r32Float
            default: throw GraphDiagnostic.unsupported("global surface \(logical) format")
            }
            for physical in ["\(logical)_read", "\(logical)_write"] {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: width, height: height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.renderTarget, .shaderRead]
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw GraphDiagnostic.missing("Metal global surface \(physical)")
                }
                RuntimeBenchmarkProbe.active?.record("feedbackTextureAllocationCount")
                RuntimeBenchmarkProbe.active?.record("feedbackTextureAllocatedBytes", Double(texture.allocatedSize))
                texture.label = physical
                targets[physical] = texture
            }
        }
        for name in graph.persistentTextureNames {
            guard let spec = graph.textures.first(where: { $0.key == name }) else {
                throw GraphDiagnostic.missing("persistent texture \(name)")
            }
            let width = try spec.width.resolve(screen: size.width,
                parameters: graph.dimensionParameters)
            let height = try spec.height.resolve(screen: size.height,
                parameters: graph.dimensionParameters)
            let format: MTLPixelFormat
            switch spec.format {
            case "rgba16f", "rgba16float": format = .rgba16Float
            case "rgba8", "rgba8unorm": format = .rgba8Unorm
            case "rgba32f", "rgba32float": format = .rgba32Float
            case "r8", "r8unorm": format = .r8Unorm
            case "r16f", "r16float": format = .r16Float
            case "r32f", "r32float": format = .r32Float
            default: throw GraphDiagnostic.unsupported("persistent texture \(name) format")
            }
            let descriptor: MTLTextureDescriptor
            if spec.is3D {
                guard let depth = try spec.depth?.resolve(screen: size.width,
                    parameters: graph.dimensionParameters) else {
                    throw GraphDiagnostic.missing("persistent 3D texture \(name) depth")
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
                    width: width, height: height, mipmapped: spec.mipmaps)
                descriptor.usage = [.renderTarget, .shaderRead]
            }
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw GraphDiagnostic.missing("Metal persistent texture \(name)")
            }
            RuntimeBenchmarkProbe.active?.record("feedbackTextureAllocationCount")
            RuntimeBenchmarkProbe.active?.record("feedbackTextureAllocatedBytes", Double(texture.allocatedSize))
            texture.label = name
            targets[name] = texture
        }
        self.targets = targets
        self.bindings = bindings
        self.clearNames = Set(targets.keys)
    }

    private init(targets: [String: MTLTexture], bindings: SurfaceManager,
                 clearNames: Set<String>, copies: [(source: MTLTexture, target: MTLTexture)]) {
        self.targets = targets
        self.bindings = bindings
        self.clearNames = clearNames
        self.pendingCopies = copies
    }

    func begin(_ command: MTLCommandBuffer) throws -> (SurfaceManager, [MTLTexture]) {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else {
            throw GraphDiagnostic.invalid("feedback state failed; call resetFeedback() before another frame")
        }
        guard pending == nil else {
            throw GraphDiagnostic.invalid("feedback frame is still uncommitted or in flight")
        }
        var transaction = bindings
        transaction.beginFrame()
        pending = command
        return (transaction, clearNames.compactMap { targets[$0] })
    }

    func accept(_ transaction: SurfaceManager, command: MTLCommandBuffer) {
        command.addCompletedHandler { [self] completed in
            lock.lock()
            defer { lock.unlock() }
            guard pending === completed else { return }
            if completed.status == .completed {
                bindings = transaction
                clearNames.removeAll()
                pendingCopies.removeAll()
            } else {
                failed = true
            }
            pending = nil
        }
    }

    func abort(_ command: MTLCommandBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if pending === command { pending = nil }
        // A partially encoded borrowed command may still be committed later.
        // New state must use fresh textures, even if that command eventually runs.
        failed = true
    }

    /// Mirrors source allocation reuse and recreateTexturePreserving. Compatible
    /// storage moves intact; resized storage starts clear unless explicitly persistent.
    func transferred(to replacement: FeedbackState, persistentNames: Set<String>) throws -> FeedbackState {
        lock.lock()
        defer { lock.unlock() }
        guard pending == nil, !failed else {
            throw GraphDiagnostic.invalid("feedback must be idle and healthy before transfer")
        }
        guard Set(targets.keys) == Set(replacement.targets.keys) else {
            throw GraphDiagnostic.unsupported("feedback topology changed during parameter update")
        }
        // An unrendered replacement with queued resamples cannot be transferred
        // again until its first accepted frame completes.
        guard pendingCopies.isEmpty else {
            throw GraphDiagnostic.invalid("complete the pending feedback migration before another update")
        }
        var moved = replacement.targets
        var clear = Set<String>()
        var copies: [(source: MTLTexture, target: MTLTexture)] = []
        for (name, source) in targets {
            guard let target = moved[name], source.device === target.device,
                  source.textureType == target.textureType,
                  source.pixelFormat == target.pixelFormat,
                  ((source.width != target.width || source.height != target.height ||
                    source.depth != target.depth) ||
                   source.mipmapLevelCount == target.mipmapLevelCount) else {
                throw GraphDiagnostic.unsupported("feedback transfer requires compatible texture formats")
            }
            if source.width == target.width && source.height == target.height &&
               source.depth == target.depth {
                moved[name] = source
                if clearNames.contains(name) { clear.insert(name) }
            } else {
                clear.insert(name)
                if source.textureType == .type2D, persistentNames.contains(name),
                   !clearNames.contains(name) {
                    copies.append((source, target))
                }
            }
        }
        return FeedbackState(targets: moved, bindings: bindings, clearNames: clear, copies: copies)
    }

    func requireIdle() throws {
        lock.lock()
        defer { lock.unlock() }
        guard pending == nil else {
            throw GraphDiagnostic.invalid("feedback frame is still uncommitted or in flight")
        }
    }
}
