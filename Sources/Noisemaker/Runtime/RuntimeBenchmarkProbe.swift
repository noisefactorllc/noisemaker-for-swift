import Foundation

/// Opt-in measurements for the standalone runtime benchmark. No probe is
/// installed in normal renderer use.
final class RuntimeBenchmarkProbe {
    private static let threadKey = "Noisemaker.RuntimeBenchmarkProbe"
    private let lock = NSLock()
    private var samples: [String: [Double]] = [:]

    init() {}

    static func install(_ probe: RuntimeBenchmarkProbe?) {
        if let probe { Thread.current.threadDictionary[threadKey] = probe }
        else { Thread.current.threadDictionary.removeObject(forKey: threadKey) }
    }

    static var active: RuntimeBenchmarkProbe? {
        Thread.current.threadDictionary[threadKey] as? RuntimeBenchmarkProbe
    }

    func record(_ key: String, _ value: Double = 1) {
        lock.lock()
        samples[key, default: []].append(value)
        lock.unlock()
    }

    static func measure<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        guard let probe = active else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            probe.record(key, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return try body()
    }

    func drain() -> [String: [Double]] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples.removeAll(keepingCapacity: true)
        return result
    }
}
