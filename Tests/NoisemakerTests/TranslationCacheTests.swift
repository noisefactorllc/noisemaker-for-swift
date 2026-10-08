import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct TranslationCacheTests {
    @Test func cachePreservesBindingsAndTranslationOptions() throws {
        let cache = TranslationCache(byteLimit: 1_000_000, entryLimit: 8)
        let translator = ShaderTranslator(cache: cache)
        let source = "@group(0) @binding(0) var<storage, read_write> result: array<f32, 4>; @compute @workgroup_size(1) fn main() { result[0] = 1.0; }"
        func translate(_ slot: UInt32, strict: Bool = true) throws -> TintTranslation {
            try translator.translate(wgsl: source, entryPoint: "main", stage: .compute,
                bindings: [TintBinding(group:0,binding:0,kind:.storage,slot:slot)], strictMath:strict)
        }
        let first = try translate(0)
        let hits = cache.snapshot.hits
        #expect(try translate(0).source == first.source)
        #expect(cache.snapshot.hits == hits + 1)
        let rebound = try translate(4)
        #expect(rebound.source != first.source)
        #expect(rebound.source.contains("[[buffer(4)]]"))
        #expect(try translate(0,strict:false).strictMath == false)
        #expect(try translate(0).strictMath == true)
        #expect(cache.snapshot.entries == 3)
        #expect(throws:(any Error).self) {
            try translator.translate(wgsl:source,entryPoint:"main",stage:.fragment,
                bindings:[TintBinding(group:0,binding:0,kind:.storage,slot:0)])
        }
        #expect(cache.snapshot.entries == 3) // failure is not reusable evidence
    }

    @Test func cacheEvictionAndOversizeDoNotChangeOutput() throws {
        let cache = TranslationCache(byteLimit: 10_000, entryLimit: 2)
        let translator = ShaderTranslator(cache:cache)
        func run(_ size:Int) throws -> TintTranslation {
            try translator.translate(wgsl:"@compute @workgroup_size(\(size)) fn main() {}",entryPoint:"main",stage:.compute)
        }
        let first = try run(1)
        _ = try run(2); _ = try run(1); _ = try run(3)
        #expect(cache.snapshot.entries == 2)
        let hits = cache.snapshot.hits
        #expect(try run(1).source == first.source)
        #expect(cache.snapshot.hits == hits + 1)
        _ = try run(2)
        #expect(cache.snapshot.hits == hits + 1) // least recently used entry was evicted
        #expect(cache.snapshot.bytes <= 10_000)
        let tiny = TranslationCache(byteLimit:1,entryLimit:2)
        let uncached = ShaderTranslator(cache:tiny)
        #expect(try uncached.translate(wgsl:"@compute @workgroup_size(1) fn main() {}",entryPoint:"main",stage:.compute).source == first.source)
        #expect(tiny.snapshot.entries == 0)
    }
}
