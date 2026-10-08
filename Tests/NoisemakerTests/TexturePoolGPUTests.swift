import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct TexturePoolGPUTests {
    @Test func reuseRequiresMatchingDescriptorAndReleasedToken() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = TexturePool(device: device)
        var first: TextureLease? = try pool.checkout(pixelFormat: .rgba8Unorm, width: 17, height: 9,
            usage: [.shaderRead, .renderTarget], storageMode: .private)
        let identifier = ObjectIdentifier(try #require(first).texture)
        let busy = try pool.checkout(pixelFormat: .rgba8Unorm, width: 17, height: 9,
            usage: [.shaderRead, .renderTarget], storageMode: .private)
        #expect(ObjectIdentifier(busy.texture) != identifier)
        first = nil
        #expect(pool.cachedCount == 1)
        let otherFormat = try pool.checkout(pixelFormat: .rgba16Float, width: 17, height: 9,
            usage: [.shaderRead, .renderTarget], storageMode: .private)
        #expect(ObjectIdentifier(otherFormat.texture) != identifier)
        let reused = try pool.checkout(pixelFormat: .rgba8Unorm, width: 17, height: 9,
            usage: [.shaderRead, .renderTarget], storageMode: .private)
        #expect(ObjectIdentifier(reused.texture) == identifier)
        #expect(pool.cachedCount == 0)
    }

    @Test func completionAndConsumerBothRetainTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = TexturePool(device: device)
        let queue = try #require(device.makeCommandQueue())
        let event = try #require(device.makeSharedEvent())
        var command: MTLCommandBuffer? = try #require(queue.makeCommandBuffer())
        var consumer: TextureLease? = try pool.checkout(pixelFormat: .rgba8Unorm, width: 17, height: 9,
            usage: [.shaderRead, .renderTarget], storageMode: .private)
        FrameCoordinator.keepAlive([try #require(consumer)], through: try #require(command))
        command?.encodeWaitForEvent(event, value: 1)
        command?.commit()
        #expect(pool.cachedCount == 0)
        event.signaledValue = 1
        command?.waitUntilCompleted()
        #expect(command?.status == .completed)
        command = nil
        #expect(pool.cachedCount == 0) // consumer still owns the token
        consumer = nil
        #expect(pool.cachedCount == 1)
    }

    @Test func purgeAndBudgetBoundRetainedStorage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = TexturePool(device: device, maxCachedBytes: 0)
        var lease: TextureLease? = try pool.checkout(pixelFormat: .rgba8Unorm, width: 17, height: 9,
            usage: [.shaderRead], storageMode: .private)
        #expect(lease != nil)
        lease = nil
        #expect(pool.cachedCount == 0 && pool.cachedBytes == 0)
        let ordinary = TexturePool(device: device)
        lease = try ordinary.checkout(pixelFormat: .rgba8Unorm, width: 17, height: 9,
            usage: [.shaderRead], storageMode: .private)
        ordinary.purge()
        lease = nil
        #expect(ordinary.cachedCount == 0)
    }
}
