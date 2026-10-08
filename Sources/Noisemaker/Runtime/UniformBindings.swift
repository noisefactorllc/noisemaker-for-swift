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
        "time", "deltaTime", "frame", "aspect", "aspectRatio", "renderScale", "audioWaveform", "audioSpectrum"]

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
                  let mappings = layout.objectFields else {
                throw GraphDiagnostic.unsupported("program \(program) packed uniform layout does not match WGSL data array")
            }
            var count = (try UniformLayout(fields: fields).byteCount + 15) / 16
            var entries: [PackedUniformEntry] = []
            var occupied = Set<Int>()
            for mapping in mappings {
                guard let slotValue = mapping.value.field("slot")?.numberValue,
                      slotValue.isFinite, slotValue.rounded() == slotValue,
                      slotValue >= 0, slotValue < 4_096,
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
                count = max(count, slot + 1)
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
            let bytes = try UniformLayout(fields: fields).byteCount
            if let entries = try inferredPackedEntries(type: raw, source: wgsl) {
                let count = (bytes + 15) / 16
                guard entries.allSatisfy({ $0.slot >= 0 && $0.slot < count &&
                    !$0.components.isEmpty && ($0.components.first! + $0.components.count) <= 4 }) else {
                    throw GraphDiagnostic.invalid("program \(program) inferred packed layout exceeds its WGSL structure")
                }
                return .packed(count: count, entries)
            }
            return .structure(fields)
        }
        let type = try parseType(raw, program: program)
        _ = try UniformLayout(fields: [UniformField(name: "binding", type: type)])
        return .direct(type)
    }

    // Mirrors the locked WebGPU backend's byte, named-comment, params-access,
    // then uniforms.data inference order. The values are packed by source names.
    private static func inferredPackedEntries(type: String, source: String) throws -> [PackedUniformEntry]? {
        func matches(_ pattern: String, _ text: String, insensitive: Bool = false) throws -> [[String]] {
            let regex = try NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive] : [])
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
                (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
            }
        }
        let structs = try matches(#"struct\s+(\w*(?:Params|Uniforms|Config|Settings))\s*\{([^}]+)\}"#, source, insensitive: true)
        guard let first = structs.first else { return nil }
        let body = first[1]
        let annotation = try matches(#"//\s*\(\s*\w+(?:\s*,\s*\w+)+\s*\)"#, body)
        let binding = try matches(#"var<uniform>\s+(\w+)\s*:\s*"# + NSRegularExpression.escapedPattern(for: first[0]) + #"\s*;"#, source)
        if !body.contains("array"), annotation.isEmpty, let variable = binding.first?.first,
           source.range(of: NSRegularExpression.escapedPattern(for: variable) + #"\.\w+"#, options: .regularExpression) != nil {
            return nil // Ordinary byte-aligned struct fields have first priority.
        }
        var entries: [PackedUniformEntry] = []
        let axes = Array("xyzw")
        func entry(_ name: String, _ slot: Int, _ components: String) -> PackedUniformEntry {
            PackedUniformEntry(name: name, slot: slot, components: components.compactMap { axes.firstIndex(of: $0) })
        }
        for definition in structs {
            let fields = try matches(#"(\w+)\s*:\s*(vec[234]<f32>|f32|i32|u32|array<[^>]+>)[^,;\n]*(?:,|;)?\s*(?://\s*\(([^)]+)\))?"#, definition[1], insensitive: true)
            for (slot, field) in fields.enumerated() {
                let scalar = ["f32", "i32", "u32"].contains(field[1])
                let count = scalar ? 1 : Int(String(field[1].dropFirst(3).prefix(1))) ?? 4
                if !field[2].isEmpty {
                    for (component, rawName) in field[2].split(separator: ",", omittingEmptySubsequences: false).prefix(count).enumerated() {
                        let name = rawName.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty && !name.hasPrefix("_") && !name.lowercased().hasPrefix("pad") && !name.lowercased().hasPrefix("unused") {
                            entries.append(entry(name, slot, String(axes[component])))
                        }
                    }
                } else if scalar { entries.append(entry(field[0], slot, "x")) }
            }
        }
        if !entries.isEmpty { return entries }
        let fields = try matches(#"(\w+)\s*:\s*(?:vec[234]<f32>|f32|i32|u32|array<[^>]+>)"#, body, insensitive: true)
        var slots: [String: Int] = [:]
        for (slot, field) in fields.enumerated() { slots[field[0]] = slot }
        for match in try matches(#"(?:let\s+)?(\w+)(?:\s*:\s*[^=\n]+)?\s*=\s*(?:i32\s*\(\s*)?params\.(\w+)\.([xyzw]+)"#, source) {
            if let slot = slots[match[1]] { entries.append(entry(match[0], slot, match[2])) }
        }
        if entries.isEmpty {
            for match in try matches(#"(?:let\s+)?(\w+)(?:\s*:\s*[^\n=]+)?\s*=\s*(?:max\s*\([^,]+,\s*)?(?:i32\s*\(\s*)?uniforms\.data\[(\d+)\]\.([xyzw]+)"#, source) {
                if let slot = Int(match[1]) { entries.append(entry(match[0], slot, match[2])) }
            }
        }
        return entries.isEmpty ? nil : entries.sorted {
            $0.slot == $1.slot ? ($0.components.first ?? 0) < ($1.components.first ?? 0) : $0.slot < $1.slot
        }
    }

    private static func parseStructure(named name: String, source: String, program: String) throws -> [UniformField] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let regex = try NSRegularExpression(pattern: #"\bstruct\s+"# + escaped + #"\s*\{([^}]*)\}"#)
        let ns = source as NSString
        guard let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else {
            throw GraphDiagnostic.unsupported("program \(program) missing uniform struct \(name)")
        }
        let body = ns.substring(with: match.range(at: 1))
        let comments = try NSRegularExpression(pattern: #"(?s)/\*.*?\*/|//[^\n]*"#)
        let bodyWithoutComments = comments.stringByReplacingMatches(in: body,
            range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
        let declarations = splitFields(bodyWithoutComments)
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
        let shorthand = Array(type)
        if shorthand.count == 5, type.hasPrefix("vec"),
           let count = Int(String(shorthand[3])), (2...4).contains(count),
           let scalar = ["f": UniformType.f32, "i": .i32, "u": .u32][String(shorthand[4])] {
            return .vector(scalar, count: count)
        }
        if let match = type.range(of: #"^mat[2-4]x[2-4](?:f|<f32>)$"#, options: .regularExpression),
           match == type.startIndex..<type.endIndex {
            return .matrix(columns: Int(String(shorthand[3]))!, rows: Int(String(shorthand[5]))!)
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

    func encode(name: String, pass: GraphPass, frame: FrameState, size: RenderSize,
                colorUniforms: Set<String> = []) throws -> Data {
        switch self {
        case .direct(let type):
            let values: [Double]
            var writerType = type
            if let authored = pass.runtimeUniformValue(named: name, frame: frame) {
                let sourceValue = AutomationEvaluator.resolve(authored, time: frame.time,
                    parameterSpec: pass.raw.field("uniformSpecs")?.field(name), inputs: frame.inputs)
                switch sourceValue {
                case .array:
                    // createSingleUniformBuffer writes JavaScript arrays through
                    // Float32Array even when the declared vector has int lanes.
                    if case .vector(let element, let count) = type,
                       element == .i32 || element == .u32 {
                        writerType = .vector(.f32, count: count)
                    }
                    values = try Self.components(name: name, pass: pass, frame: frame,
                        size: size, colorUniforms: colorUniforms,
                        expectedCount: Self.scalarCount(type))
                case .number, .bool:
                    values = try Self.components(name: name, pass: pass, frame: frame,
                        size: size, colorUniforms: colorUniforms,
                        expectedCount: Self.scalarCount(type))
                case .string where colorUniforms.contains(name):
                    values = try Self.components(name: name, pass: pass, frame: frame,
                        size: size, colorUniforms: colorUniforms,
                        expectedCount: Self.scalarCount(type))
                default:
                    values = Self.directDefault(type)
                }
            } else {
                values = Self.isGlobal(name)
                    ? try Self.components(name: name, pass: pass, frame: frame,
                        size: size, colorUniforms: colorUniforms,
                        expectedCount: Self.scalarCount(type))
                    : Self.directDefault(type)
            }
            let layout = try UniformLayout(fields: [UniformField(name: name, type: writerType)])
            return try UniformWriter.encodeSource(values: [name: Self.convert(values, to: writerType)], layout: layout)
        case .structure(let fields):
            let layout = try UniformLayout(fields: fields)
            var values: [String: [Double]] = [:]
            for field in fields {
                if field.name.hasPrefix("_") || field.name.lowercased().hasPrefix("pad") {
                    values[field.name] = [Double](repeating: 0, count: Self.scalarCount(field.type))
                } else {
                    values[field.name] = Self.convert(try Self.components(name: field.name, pass: pass,
                        frame: frame, size: size, colorUniforms: colorUniforms,
                        expectedCount: Self.scalarCount(field.type), aliases: true, sourceStruct: true), to: field.type)
                }
            }
            var bytes = try UniformWriter.encodeSource(values: values, layout: layout)
            // WebGPU allocates at least a 16-byte uniform buffer even when
            // the declared structure ends with only a scalar or vec2.
            bytes.append(contentsOf: repeatElement(UInt8(0), count: (16 - bytes.count % 16) % 16))
            return bytes
        case .packed(let count, let mappings):
            var slots = [Double](repeating: 0, count: count * 4)
            for entry in mappings {
                let values = try Self.packedComponents(name: entry.name, componentCount: entry.components.count,
                    pass: pass, frame: frame, size: size, colorUniforms: colorUniforms)
                guard let start = entry.components.first else { continue }
                for (offset, value) in values.enumerated() {
                    slots[entry.slot * 4 + start + offset] = value
                }
            }
            let layout = try UniformLayout(fields: [UniformField(name: name,
                type: .array(.vector(.f32, count: 4), count: count))])
            return try UniformWriter.encodeSource(values: [name: slots], layout: layout)
        }
    }

    private static func directDefault(_ type: UniformType) -> [Double] {
        if case .matrix(columns: 3, rows: 3) = type {
            return [1, 0, 0, 0, 1, 0, 0, 0, 1]
        }
        return [Double](repeating: 0, count: scalarCount(type))
    }

    private static func packedComponents(name: String, componentCount: Int,
                                         pass: GraphPass, frame: FrameState,
                                         size: RenderSize,
                                         colorUniforms: Set<String>) throws -> [Double] {
        let value: GraphValue
        if let explicit = pass.runtimeUniformValue(named: name, frame: frame), !explicit.isUndefined {
            value = AutomationEvaluator.resolve(explicit, time: frame.time,
                parameterSpec: pass.raw.field("uniformSpecs")?.field(name), inputs: frame.inputs)
        } else {
            let global = try components(name: name, pass: pass, frame: frame,
                size: size, colorUniforms: colorUniforms, aliases: true)
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
        case .string(let hex) where colorUniforms.contains(name):
            return try colorComponents(hex, pass: pass.id, name: name).prefix(componentCount).map { $0 }
        default: return [] // Upstream writes neither booleans nor objects into vector slots.
        }
    }

    // JavaScript Math.round followed by DataView's modulo-2^32 integer conversion.
    // The public ABI writer remains strict; the source runtime performs this coercion.
    private static func convert(_ values: [Double], to type: UniformType) -> [Double] {
        let scalar: UniformType
        switch type {
        case .vector(let element, _): scalar = element
        default: scalar = type
        }
        guard scalar == .i32 || scalar == .u32 else { return values }
        return values.map { value in
            guard value.isFinite else { return 0 }
            let rounded = floor(value + 0.5)
            let remainder = rounded.truncatingRemainder(dividingBy: 4_294_967_296)
            let unsigned = remainder < 0 ? remainder + 4_294_967_296 : remainder
            return scalar == .i32 && unsigned >= 2_147_483_648 ? unsigned - 4_294_967_296 : unsigned
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

    private static func components(name: String, pass: GraphPass, frame: FrameState,
                                   size: RenderSize, colorUniforms: Set<String>,
                                   expectedCount: Int? = nil, aliases: Bool = false, sourceStruct: Bool = false) throws -> [Double] {
        if let raw = pass.runtimeUniformValue(named: name, frame: frame), !raw.isUndefined {
            let value = AutomationEvaluator.resolve(raw, time: frame.time,
                parameterSpec: pass.raw.field("uniformSpecs")?.field(name), inputs: frame.inputs)
            if sourceStruct {
                let count = expectedCount ?? 1
                switch value {
                case .number(let value): return [value] + [Double](repeating: 0, count: max(0, count - 1))
                case .bool(let flag): return [count == 1 && flag ? 1 : 0] + [Double](repeating: 0, count: max(0, count - 1))
                case .array(let members) where count > 1:
                    let supplied = try members.prefix(count).flatMap { try numeric($0, pass: pass.id, name: name) }
                    return Array(supplied.prefix(count)) + [Double](repeating: 0, count: max(0, count - supplied.count))
                default: return [Double](repeating: 0, count: count)
                }
            }
            if case .object = value,
               case .some(.tagged("function", _)) = value.field("fn"),
               let expectedCount {
                // The locked WebGPU packer does not call source Func wrappers.
                // It leaves each corresponding scalar component at zero.
                return [Double](repeating: 0, count: expectedCount)
            }
            if case .string(let hex) = value, colorUniforms.contains(name) {
                return try colorComponents(hex, pass: pass.id, name: name)
            }
            if case .array = value, colorUniforms.contains(name) {
                var components = Array(try numeric(value, pass: pass.id, name: name).prefix(3))
                while components.count < 3 { components.append(0) }
                return components
            }
            return try numeric(value, pass: pass.id, name: name)
        }
        if aliases {
            if name == "width" || name == "height" {
                let resolution = try components(name: "resolution", pass: pass, frame: frame, size: size,
                    colorUniforms: colorUniforms)
                return [resolution.indices.contains(name == "width" ? 0 : 1) ? resolution[name == "width" ? 0 : 1] : 0]
            }
            if name == "channels" || (sourceStruct && name == "channelCount") { return [4] }
        }
        if name == "audioWaveform" || name == "audioSpectrum" {
            let samples = name == "audioWaveform" ? frame.inputs.audio?.waveform : frame.inputs.audio?.spectrum
            guard samples == nil || samples?.count == 128 else {
                throw GraphDiagnostic.invalid("\(name) requires 128 normalized samples")
            }
            if let samples { return samples.map(Double.init) }
            return [Double](repeating: name == "audioWaveform" ? 0.5 : 0, count: 128)
        }
        switch name {
        case "resolution", "fullResolution": return [Double(size.width), Double(size.height)]
        case "tileOffset": return [0, 0]
        case "time": return [frame.time]
        case "deltaTime": return [frame.delta]
        case "frame": return [Double(frame.frameIndex)]
        case "aspect", "aspectRatio": return [Double(size.width) / Double(size.height)]
        case "renderScale": return [1]
        default: return [Double](repeating: 0, count: expectedCount ?? 1)
        }
    }

    private static func colorComponents(_ hex: String, pass: String,
                                        name: String) throws -> [Double] {
        let digits = Array(hex.utf8)
        guard (digits.count == 7 || digits.count == 9), digits.first == 35 else {
            throw GraphDiagnostic.unsupported("pass \(pass) invalid color \(name)")
        }
        var values: [Double] = []
        for pair in [1, 3, 5] {
            guard let component = UInt8(String(decoding: digits[pair..<(pair + 2)], as: UTF8.self),
                                        radix: 16) else {
                throw GraphDiagnostic.unsupported("pass \(pass) invalid color \(name)")
            }
            values.append(Double(component) / 255)
        }
        return values
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

extension GraphPass {
    /// Host onUpdate values are per graph node and only fill undefined pass uniforms.
    /// Authored values retain their source-pipeline priority.
    func runtimeUniformValue(named name: String, frame: FrameState) -> GraphValue? {
        let authored = uniforms.first(where: { $0.name == name })?.value
        if let authored, !authored.isUndefined { return authored }
        guard let node = raw.field("nodeId")?.stringValue else { return authored }
        return frame.hostUniforms[node]?[name] ?? authored
    }
}
