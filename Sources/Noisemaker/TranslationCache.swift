import Foundation

struct TranslationKey: Hashable {
    let wgsl: String
    let entryPoint: String
    let stage: TintStage
    let bindings: [TintBinding]
    let bufferSizes: [TintBufferSize]
    let bufferSizesOffset: UInt32?
    let immediateSlot: UInt32?
    let appleGPUFamily9: Bool
    let strictMath: Bool
    // The cache is process-local and cannot survive a translator revision change.
}

/// Bounded process-local LRU. No files, runtime downloads, or persistent shader cache.
final class TranslationCache: @unchecked Sendable {
    static let shared = TranslationCache(byteLimit: 16 * 1024 * 1024, entryLimit: 256)
    private let lock = NSLock()
    private let byteLimit: Int
    private let entryLimit: Int
    private var values: [TranslationKey: (TintTranslation, Int)] = [:]
    private var order: [TranslationKey] = []
    private var bytes = 0
    private var hits: UInt64 = 0

    init(byteLimit: Int, entryLimit: Int) {
        self.byteLimit = max(0, byteLimit)
        self.entryLimit = max(0, entryLimit)
    }
    var snapshot: (entries: Int, bytes: Int, hits: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (values.count,bytes,hits)
    }
    func lookup(_ key: TranslationKey) -> TintTranslation? {
        lock.lock(); defer { lock.unlock() }
        guard let item = values[key] else { return nil }
        hits &+= 1
        order.removeAll { $0 == key }
        order.append(key)
        return item.0
    }
    func insert(_ translation: TintTranslation, for key: TranslationKey) {
        // Source storage plus a conservative fixed/table metadata allowance.
        let cost = key.wgsl.utf8.count + translation.source.utf8.count + key.entryPoint.utf8.count * 2 +
            (key.bindings.count + key.bufferSizes.count) * 64 + 1024
        guard entryLimit > 0, cost <= byteLimit else { return }
        lock.lock(); defer { lock.unlock() }
        if let previous = values.removeValue(forKey: key) { bytes -= previous.1 }
        order.removeAll { $0 == key }
        while !order.isEmpty && (values.count >= entryLimit || bytes > byteLimit - cost) {
            let oldest = order.removeFirst()
            if let removed = values.removeValue(forKey: oldest) { bytes -= removed.1 }
        }
        values[key] = (translation,cost)
        order.append(key)
        bytes += cost
    }
}
