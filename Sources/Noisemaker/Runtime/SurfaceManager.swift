import Foundation

/// Value-semantic binding transaction. Metal resource ownership is separate:
/// callers may prepare a copy and publish it only for an accepted frame.
struct SurfaceManager {
    struct Pair {
        var read: String
        var write: String
    }
    private let names: [String]
    private var surfaces: [String: Pair]
    private var frame: [String: Pair] = [:]
    private var frameActive = false

    init(surfaces names: [String]) throws {
        guard Set(names).count == names.count, names.allSatisfy({ !$0.isEmpty }) else {
            throw GraphDiagnostic.invalid("global surface names must be unique and nonempty")
        }
        self.names = names
        self.surfaces = Dictionary(uniqueKeysWithValues: names.map {
            ($0, Pair(read: "global_\($0)_read", write: "global_\($0)_write"))
        })
    }

    var physicalTargets: [String] {
        names.flatMap { name in ["global_\(name)_read", "global_\(name)_write"] }
    }

    mutating func beginFrame() { frame = surfaces; frameActive = true }

    func readTarget(_ logical: String) throws -> String {
        guard logical.hasPrefix("global_") else { return logical }
        let name = String(logical.dropFirst(7))
        guard let pair = frame[name] else { throw GraphDiagnostic.missing("global surface \(name)") }
        return pair.read
    }

    func writeTarget(_ logical: String) throws -> String {
        guard logical.hasPrefix("global_") else { return logical }
        let name = String(logical.dropFirst(7))
        guard let pair = frame[name] else { throw GraphDiagnostic.missing("global surface \(name)") }
        return pair.write
    }

    // Mirrors updateFrameSurfaceBindings followed by adoptIterationBindings.
    // In particular, a repeat after a seed must advance the frame-local pair,
    // never recompute it from the previous frame's stale persistent pair.
    mutating func advance(outputs: [String], repeated: Bool) throws {
        guard frameActive else { throw GraphDiagnostic.invalid("surface frame has not begun") }
        guard Set(outputs).count == outputs.count else {
            throw GraphDiagnostic.invalid("one pass cannot write a target twice")
        }
        for logical in outputs where logical.hasPrefix("global_") {
            guard frame[String(logical.dropFirst(7))] != nil else {
                throw GraphDiagnostic.missing("global surface \(logical)")
            }
        }
        for logical in outputs where logical.hasPrefix("global_") {
            let name = String(logical.dropFirst(7))
            guard let pair = frame[name] else { throw GraphDiagnostic.missing("global surface \(name)") }
            frame[name] = Pair(read: pair.write, write: pair.read)
            if repeated { surfaces[name] = frame[name] }
        }
    }

    mutating func finishFrame() throws {
        guard frameActive else { throw GraphDiagnostic.invalid("surface frame has not begun") }
        frameActive = false
        for name in names {
            if Self.isStateSurface(name), let final = frame[name] {
                surfaces[name] = final
            } else if let prior = surfaces[name] {
                // This intentionally matches the authority's display-surface
                // swap, including a pair adopted during a repeated pass.
                surfaces[name] = Pair(read: prior.write, write: prior.read)
            }
        }
    }

    private static func isStateSurface(_ name: String) -> Bool {
        ["xyz", "vel", "rgba", "trail"].contains(name) ||
        ["_xyz", "_vel", "_rgba", "_trail"].contains(where: name.hasSuffix) ||
        name.contains("state") || name.contains("State") ||
        name.range(of: #"^(xyz|vel|rgba|points_trail)_node_\d+$"#, options: .regularExpression) != nil
    }
}
