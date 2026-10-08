import Foundation

/// Native linear-scan allocation matching the locked `runtime/resources.js`.
/// The returned map preserves virtual texture insertion order.
public enum ResourceAllocator {
    private struct Lifetime {
        var start: Int
        var end: Int
    }

    private struct FreeSlot {
        let id: String
        let availableAfter: Int
    }

    public static func allocate(passes: [GraphValue]) throws -> GraphValue {
        var lifetime: [String: Lifetime] = [:]
        var inputsByPass: [[String]] = []
        var outputsByPass: [[String]] = []

        for (index, pass) in passes.enumerated() {
            guard pass.objectFields != nil else {
                throw GraphDiagnostic.invalid("allocation pass \(index) is not an object")
            }
            let inputs = try textureNames(pass.field("inputs"), context: "pass \(index) inputs")
            let outputs = try textureNames(pass.field("outputs"), context: "pass \(index) outputs")
            inputsByPass.append(inputs)
            outputsByPass.append(outputs)
            for texture in inputs + outputs where !texture.isEmpty && !texture.hasPrefix("global_") {
                if var live = lifetime[texture] {
                    live.end = index
                    lifetime[texture] = live
                } else {
                    lifetime[texture] = Lifetime(start: index, end: index)
                }
            }
        }

        var allocations: [GraphMapEntry] = []
        var allocated: [String: String] = [:]
        var freeList: [FreeSlot] = []
        var physicalCount = 0
        for index in passes.indices {
            for texture in outputsByPass[index] where !texture.hasPrefix("global_") {
                if allocated[texture] != nil { continue }
                let physical: String
                if let freeIndex = freeList.firstIndex(where: { $0.availableAfter < index }) {
                    physical = freeList.remove(at: freeIndex).id
                } else {
                    physical = "phys_\(physicalCount)"
                    physicalCount += 1
                }
                allocated[texture] = physical
                allocations.append(GraphMapEntry(key: .string(texture), value: .string(physical)))
            }

            // Object.values may repeat the same input texture. The source
            // releases its physical slot once, after its last input use.
            var released: Set<String> = []
            for texture in inputsByPass[index] where !texture.hasPrefix("global_") {
                guard released.insert(texture).inserted,
                      lifetime[texture]?.end == index,
                      let physical = allocated[texture] else { continue }
                freeList.append(FreeSlot(id: physical, availableAfter: index))
            }
        }
        return .map(allocations)
    }

    private static func textureNames(_ value: GraphValue?, context: String) throws -> [String] {
        guard let value else { return [] }
        guard let fields = value.objectFields else {
            throw GraphDiagnostic.invalid("\(context) is not an object")
        }
        return try fields.map { field in
            guard let name = field.value.stringValue else {
                throw GraphDiagnostic.invalid("\(context) contains a non-string texture")
            }
            return name
        }
    }
}
