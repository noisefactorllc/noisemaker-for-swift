import Foundation
import Metal

/// Transient textures only. Persistent feedback targets never enter this pool.
/// A checkout token must be retained by both the output lease and GPU work.
final class TexturePool: @unchecked Sendable {
    let device: MTLDevice
    private let lock = NSLock()
    private let maxCachedBytes: Int
    private let maxPerDescriptor: Int
    private var available: [TextureDescriptorKey: [MTLTexture]] = [:]
    private var bytes = 0
    private var generation: UInt64 = 0

    init(device: MTLDevice, maxCachedBytes: Int = 64 * 1024 * 1024, maxPerDescriptor: Int = 3) {
        self.device = device
        self.maxCachedBytes = max(0, maxCachedBytes)
        self.maxPerDescriptor = max(0, maxPerDescriptor)
    }

    var cachedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var cachedCount: Int { lock.lock(); defer { lock.unlock() }; return available.values.reduce(0) { $0 + $1.count } }

    func checkout(pixelFormat: MTLPixelFormat, width: Int, height: Int,
                  usage: MTLTextureUsage, storageMode: MTLStorageMode) throws -> TextureLease {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
            width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = storageMode
        return try checkout(descriptor: descriptor)
    }

    func checkout(descriptor: MTLTextureDescriptor) throws -> TextureLease {
        guard descriptor.width > 0, descriptor.height > 0, descriptor.depth > 0,
              descriptor.mipmapLevelCount > 0, descriptor.arrayLength > 0,
              descriptor.sampleCount > 0 else {
            throw GraphDiagnostic.invalid("pooled texture descriptor has a nonpositive extent")
        }
        let key = TextureDescriptorKey(descriptor)
        lock.lock()
        let epoch = generation
        if var cached = available[key], let texture = cached.popLast() {
            RuntimeBenchmarkProbe.active?.record("texturePoolReuseCount")
            bytes -= texture.allocatedSize
            if cached.isEmpty { available.removeValue(forKey: key) }
            else { available[key] = cached }
            lock.unlock()
            return TextureLease(texture: texture, pool: self, key: key, generation: epoch)
        }
        lock.unlock()
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("Metal texture allocation")
        }
        RuntimeBenchmarkProbe.active?.record("texturePoolAllocationCount")
        RuntimeBenchmarkProbe.active?.record("texturePoolAllocatedBytes", Double(texture.allocatedSize))
        return TextureLease(texture: texture, pool: self, key: key, generation: epoch)
    }

    /// Drop idle storage and prevent older outstanding tokens from repopulating it.
    func purge() {
        lock.lock(); defer { lock.unlock() }
        available.removeAll()
        bytes = 0
        generation &+= 1
    }

    fileprivate func recycle(_ texture: MTLTexture, key: TextureDescriptorKey, generation epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard epoch == generation, texture.allocatedSize <= maxCachedBytes - bytes,
              (available[key]?.count ?? 0) < maxPerDescriptor else { return }
        texture.label = nil
        available[key, default: []].append(texture)
        bytes += texture.allocatedSize
    }
}

final class TextureLease {
    let texture: MTLTexture
    private let pool: TexturePool
    private let key: TextureDescriptorKey
    private let generation: UInt64
    fileprivate init(texture: MTLTexture, pool: TexturePool, key: TextureDescriptorKey, generation: UInt64) {
        self.texture = texture
        self.pool = pool
        self.key = key
        self.generation = generation
    }
    deinit { pool.recycle(texture, key: key, generation: generation) }
}

// Capture every public allocation/layout property, including swizzles and
// compression, rather than accidentally aliasing same-sized unlike textures.
fileprivate struct TextureDescriptorKey: Hashable {
    let type: UInt, format: UInt
    let width: Int, height: Int, depth: Int, arrayLength: Int, mipLevels: Int, samples: Int
    let resources: UInt, usage: UInt, compression: Int
    let optimized: Bool
    let red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
    init(_ descriptor: MTLTextureDescriptor) {
        type = descriptor.textureType.rawValue
        format = descriptor.pixelFormat.rawValue
        width = descriptor.width; height = descriptor.height; depth = descriptor.depth
        arrayLength = descriptor.arrayLength; mipLevels = descriptor.mipmapLevelCount; samples = descriptor.sampleCount
        resources = descriptor.resourceOptions.rawValue; usage = descriptor.usage.rawValue
        optimized = descriptor.allowGPUOptimizedContents
        compression = descriptor.compressionType.rawValue
        red = descriptor.swizzle.red.rawValue; green = descriptor.swizzle.green.rawValue
        blue = descriptor.swizzle.blue.rawValue; alpha = descriptor.swizzle.alpha.rawValue
    }
}
