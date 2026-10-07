import Foundation

struct PackedUniformEntry {
    let name: String
    let slot: Int
    let components: [Int]
}

enum UniformPlan {
    case direct(UniformType)
    case structure([UniformField])
    case packed(count: Int, [PackedUniformEntry])

    private static let globalNames: Set<String> = ["resolution", "fullResolution", "tileOffset",
        "time", "deltaTime", "frame", "aspect", "aspectRatio", "renderScale"]

    var requiredNames: Set<String> {
        switch self {
        case .direct: return []
        case .structure(let fields): return Set(fields.filter { !$0.name.hasPrefix("_pad") }.map(\.name))
        case .packed(_, let entries): return Set(entries.map(\.name))
        }
    }

    static func isGlobal(_ name: String) -> Bool { globalNames.contains(name) }

    static func parse(type raw: String, wgsl: String, layout: GraphValue?, program: String) throws -> UniformPlan {
        if let layout, !layout.isUndefined {
            guard let fields = try? parseStructure(named: raw, source: wgsl, program: program),
                  fields.count == 1, fields[0].name == "data",
                  case .array(.vector(.f32, count: 4), let count) = fields[0].type,
                  let mappings = layout.objectFields else {
                throw GraphDiagnostic.unsupported("program \(program) packed uniform layout does not match WGSL data array")
            }
            _ = try UniformLayout(fields: fields)
            var entries: [PackedUniformEntry] = []
            var occupied = Set<Int>()
            for mapping in mappings {
                guard let slotValue = mapping.value.field("slot")?.numberValue,
                      slotValue.rounded() == slotValue, slotValue >= 0,
                      slotValue < Double(count),
                      let components = mapping.value.field("components")?.stringValue,
                      !components.isEmpty, components.count <= 4 else {
                    throw GraphDiagnostic.invalid("program \(program) invalid packed uniform \(mapping.name)")
                }
                let offsets = try components.map { component -> Int in
                    switch component {
                    case "x": return 0
                    case "y": return 1
                    case "z": return 2
                    case "w": return 3
                    default: throw GraphDiagnostic.invalid("program \(program) invalid packed component")
                    }
                }
                guard let first = offsets.first,
                      offsets == Array(first..<(first + offsets.count)),
                      first + offsets.count <= 4 else {
                    throw GraphDiagnostic.unsupported("program \(program) packed components must be contiguous")
                }
                let slot = Int(slotValue)
                for component in offsets {
                    guard occupied.insert(slot * 4 + component).inserted else {
                        throw GraphDiagnostic.invalid("program \(program) overlapping packed uniform slots")
                    }
                }
                entries.append(PackedUniformEntry(name: mapping.name, slot: slot, components: offsets))
            }
            return .packed(count: count, entries)
        }
        if let fields = try? parseStructure(named: raw, source: wgsl, program: program) {
            _ = try UniformLayout(fields: fields)
            return .structure(fields)
        }
        let type = try parseType(raw, program: program)
        _ = try UniformLayout(fields: [UniformField(name: "binding", type: type)])
        return .direct(type)
    }

    private static func parseStructure(named name: String, source: String, program: String) throws -> [UniformField] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let regex = try NSRegularExpression(pattern: #"\bstruct\s+"# + escaped + #"\s*\{([^}]*)\}"#)
        let ns = source as NSString
        guard let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else {
            throw GraphDiagnostic.unsupported("program \(program) missing uniform struct \(name)")
        }
        let body = ns.substring(with: match.range(at: 1))
        let declarations = splitFields(body)
        guard !declarations.isEmpty else {
            throw GraphDiagnostic.unsupported("program \(program) empty uniform struct \(name)")
        }
        return try declarations.map { field in
            guard let colon = field.firstIndex(of: ":") else {
                throw GraphDiagnostic.unsupported("program \(program) malformed uniform struct field \(field)")
            }
            let key = field[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let type = field[field.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw GraphDiagnostic.invalid("program \(program) empty uniform field") }
            return UniformField(name: key, type: try parseType(type, program: program))
        }
    }

    private static func splitFields(_ body: String) -> [String] {
        var result: [String] = [], current = "", depth = 0
        for character in body {
            if character == "<" { depth += 1 }
            if character == ">" { depth -= 1 }
            if character == "," && depth == 0 {
                let field = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !field.isEmpty { result.append(field) }
                current = ""
            } else { current.append(character) }
        }
        let final = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty { result.append(final) }
        return result
    }

    private static func parseType(_ raw: String, program: String) throws -> UniformType {
        let type = raw.filter { !$0.isWhitespace }
        switch type {
        case "f32": return .f32
        case "i32": return .i32
        case "u32": return .u32
        default: break
        }
        if type.hasPrefix("vec"), let opening = type.firstIndex(of: "<"), type.hasSuffix(">"),
           let count = Int(type[type.index(type.startIndex, offsetBy: 3)..<opening]) {
            let scalar = String(type[type.index(after: opening)..<type.index(before: type.endIndex)])
            return .vector(try parseType(scalar, program: program), count: count)
        }
        if type.hasPrefix("array<"), type.hasSuffix(">") {
            let inner = String(type.dropFirst(6).dropLast())
            var depth = 0, separator: String.Index?
            for index in inner.indices {
                if inner[index] == "<" { depth += 1 }
                if inner[index] == ">" { depth -= 1 }
                if inner[index] == "," && depth == 0 { separator = index; break }
            }
            if let separator,
               let count = Int(inner[inner.index(after: separator)...]) {
                return .array(try parseType(String(inner[..<separator]), program: program), count: count)
            }
        }
        throw GraphDiagnostic.unsupported("program \(program) uniform type \(raw)")
    }

    func encode(name: String, pass: GraphPass, frame: FrameState, size: RenderSize) throws -> Data {
        switch self {
        case .direct(let type):
            let values = try Self.components(name: name, pass: pass, frame: frame, size: size)
            let layout = try UniformLayout(fields: [UniformField(name: name, type: type)])
            return try UniformWriter.encode(values: [name: values], layout: layout)
        case .structure(let fields):
            let layout = try UniformLayout(fields: fields)
            var values: [String: [Double]] = [:]
            for field in fields {
                if field.name.hasPrefix("_pad"),
                   pass.uniforms.first(where: { $0.name == field.name }) == nil {
                    values[field.name] = [Double](repeating: 0, count: Self.scalarCount(field.type))
                } else {
                    values[field.name] = try Self.components(name: field.name, pass: pass, frame: frame, size: size)
                }
            }
            return try UniformWriter.encode(values: values, layout: layout)
        case .packed(let count, let mappings):
            var slots = [Double](repeating: 0, count: count * 4)
            for entry in mappings {
                let values = try Self.packedComponents(name: entry.name, componentCount: entry.components.count,
                    pass: pass, frame: frame, size: size)
                guard let start = entry.components.first else { continue }
                for (offset, value) in values.enumerated() {
                    slots[entry.slot * 4 + start + offset] = value
                }
            }
            let layout = try UniformLayout(fields: [UniformField(name: name,
                type: .array(.vector(.f32, count: 4), count: count))])
            return try UniformWriter.encode(values: [name: slots], layout: layout)
        }
    }

    private static func packedComponents(name: String, componentCount: Int,
                                         pass: GraphPass, frame: FrameState,
                                         size: RenderSize) throws -> [Double] {
        let value: GraphValue
        if let explicit = pass.uniforms.first(where: { $0.name == name })?.value {
            value = explicit
        } else {
            let global = try components(name: name, pass: pass, frame: frame, size: size)
            value = global.count == 1 ? .number(global[0]) : .array(global.map(GraphValue.number))
        }
        if componentCount == 1 {
            switch value {
            case .number(let number): return [number]
            case .bool(let flag): return [flag ? 1 : 0]
            default: return [] // Upstream leaves a scalar slot zero for array values.
            }
        }
        switch value {
        case .number(let number): return [number]
        case .array(let members):
            return try members.prefix(componentCount).map { member in
                guard case .number(let number) = member else {
                    throw GraphDiagnostic.unsupported("pass \(pass.id) packed uniform \(name) has nonnumeric array member")
                }
                return number
            }
        default: return [] // Upstream writes neither booleans nor objects into vector slots.
        }
    }

    private static func scalarCount(_ type: UniformType) -> Int {
        switch type {
        case .f32, .i32, .u32: return 1
        case .vector(_, let count): return count
        case .matrix(let columns, let rows): return columns * rows
        case .array(let element, let count): return scalarCount(element) * count
        case .structure(let fields): return fields.reduce(0) { $0 + scalarCount($1.type) }
        }
    }

    private static func components(name: String, pass: GraphPass, frame: FrameState, size: RenderSize) throws -> [Double] {
        if let value = pass.uniforms.first(where: { $0.name == name })?.value {
            return try numeric(value, pass: pass.id, name: name)
        }
        switch name {
        case "resolution", "fullResolution": return [Double(size.width), Double(size.height)]
        case "tileOffset": return [0, 0]
        case "time": return [frame.time]
        case "deltaTime": return [frame.delta]
        case "frame": return [Double(frame.frameIndex)]
        case "aspect", "aspectRatio": return [Double(size.width) / Double(size.height)]
        case "renderScale": return [1]
        default: throw GraphDiagnostic.missing("pass \(pass.id) uniform \(name)")
        }
    }

    private static func numeric(_ value: GraphValue, pass: String, name: String) throws -> [Double] {
        switch value {
        case .number(let number): return [number]
        case .bool(let flag): return [flag ? 1 : 0]
        case .array(let values):
            return try values.flatMap { try numeric($0, pass: pass, name: name) }
        default: throw GraphDiagnostic.unsupported("pass \(pass) uniform \(name) is not numeric")
        }
    }
}
