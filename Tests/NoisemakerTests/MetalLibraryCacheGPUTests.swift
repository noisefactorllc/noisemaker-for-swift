import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct MetalLibraryCacheGPUTests {
    private let a = "#include <metal_stdlib>\nusing namespace metal; kernel void first() {}"
    private let b = "#include <metal_stdlib>\nusing namespace metal; kernel void second() {}"
    @Test func boundedLibraryReusePreservesEntryPoints() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cache = MetalLibraryCache(maxEntries:1,maxSourceBytes:4096)
        let first = try cache.library(device:device,source:a)
        let reused = try cache.library(device:device,source:a)
        #expect(first === reused)
        #expect(cache.snapshot.hits == 1)
        let second = try cache.library(device:device,source:b)
        #expect(second.makeFunction(name:"second") != nil)
        #expect(second.makeFunction(name:"first") == nil)
        #expect(cache.snapshot.entries == 1)
        #expect(cache.snapshot.sourceBytes == b.utf8.count)
        #expect(first.makeFunction(name:"first") != nil) // Eviction keeps active users valid.
        _ = try cache.library(device:device,source:a)
        #expect(cache.snapshot.hits == 1)
    }
    @Test func oversizedAndInvalidSourcesDoNotOccupyCache() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cache = MetalLibraryCache(maxEntries:2,maxSourceBytes:1)
        let library = try cache.library(device:device,source:a)
        #expect(library.makeFunction(name:"first") != nil)
        #expect(cache.snapshot.entries == 0)
        #expect(throws:(any Error).self) {try cache.library(device:device,source:"not a metal program")}
        #expect(cache.snapshot.entries == 0)
    }
}
