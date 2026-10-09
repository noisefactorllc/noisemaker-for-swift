import Foundation
import Metal

/// Bounded process-local compilation reuse. Initialization may compile while
/// holding this lock; frame encoding never waits on this cache.
final class MetalLibraryCache: @unchecked Sendable {
    static let shared = MetalLibraryCache(maxEntries:64,maxSourceBytes:16*1024*1024)
    // This immutable profile matches the qualified WebGPU numeric path for
    // wormhole, billboard, noise, blur, mesh, and compute fixtures.
    static let fastMathEnabled = true
    private struct Key: Hashable { let device:ObjectIdentifier, source:String, fastMath:Bool }
    private struct Entry { let device:MTLDevice, library:MTLLibrary, cost:Int }
    private let lock = NSLock()
    private let maxEntries:Int, maxSourceBytes:Int
    private var entries:[Key:Entry] = [:]
    private var order:[Key] = []
    private var sourceBytes = 0
    private var hits = 0

    init(maxEntries:Int,maxSourceBytes:Int) {
        self.maxEntries = max(0,maxEntries)
        self.maxSourceBytes = max(0,maxSourceBytes)
    }
    static func library(device:MTLDevice,source:String) throws -> MTLLibrary {
        try shared.library(device:device,source:source)
    }
    func library(device:MTLDevice,source:String) throws -> MTLLibrary {
        let key = Key(device:ObjectIdentifier(device),source:source,
                      fastMath:Self.fastMathEnabled)
        lock.lock(); defer {lock.unlock()}
        if let entry = entries[key] {
            hits += 1
            RuntimeBenchmarkProbe.active?.record("metalLibraryCacheHitCount")
            order.removeAll {$0 == key}
            order.append(key)
            return entry.library
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = Self.fastMathEnabled
        let library = try RuntimeBenchmarkProbe.measure("metalLibraryCompileMS") {
            try device.makeLibrary(source:source,options:options)
        }
        RuntimeBenchmarkProbe.active?.record("metalLibraryCompileCount")
        let cost = source.utf8.count
        guard maxEntries > 0, cost <= maxSourceBytes else { return library }
        while !order.isEmpty && (entries.count >= maxEntries || sourceBytes + cost > maxSourceBytes) {
            let oldest = order.removeFirst()
            if let removed = entries.removeValue(forKey:oldest) {sourceBytes -= removed.cost}
        }
        entries[key] = Entry(device:device,library:library,cost:cost)
        sourceBytes += cost
        order.append(key)
        return library
    }
    var snapshot:(entries:Int,sourceBytes:Int,hits:Int) {
        lock.lock();defer{lock.unlock()}
        return (entries.count,sourceBytes,hits)
    }
}
