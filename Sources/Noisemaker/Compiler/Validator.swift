import Foundation

public struct CompilerIncomplete: Error, LocalizedError, Sendable {
    public let stage: String
    public let detail: String

    public init(stage: String, detail: String) {
        self.stage = stage
        self.detail = detail
    }

    public var errorDescription: String? { "Native \(stage) incomplete: \(detail)" }
}

/// The source-ordered semantic step planner from `lang/validator.js`.
/// Unsupported dynamic expressions currently fail explicitly; they never
/// enter the expansion stage as a plausible but incorrectly evaluated value.
public enum NoisemakerValidator {
    public static func validate(_ ast: ParserValue, registry: EffectRegistry) throws -> ParserValue {
        var validator = Validator(registry: registry)
        return try validator.validate(ast)
    }

    private struct Validator {
        private static let stateValues: Set<String> = [
            "time", "frame", "mouse", "resolution", "seed", "a", "u1", "u2", "u3", "u4",
            "s1", "s2", "b1", "b2", "a1", "a2", "deltaTime"
        ]
        let registry: EffectRegistry
        var tempIndex = 0
        var diagnostics: [ParserValue] = []
        var symbols: [String: ParserValue] = [:]
        var searchOrder: [String] = []

        mutating func validate(_ ast: ParserValue) throws -> ParserValue {
            guard ast.type == "Program",
                  let namespace = ast.field("namespace"),
                  let search = namespace.field("searchOrder")?.elements,
                  let plans = ast.field("plans")?.elements else {
                throw CompilerIncomplete(stage: "validator", detail: "malformed parser program")
            }
            searchOrder = try search.map { value in
                guard let name = value.string else {
                    throw CompilerIncomplete(stage: "validator", detail: "non-string search namespace")
                }
                return name
            }
            guard !searchOrder.isEmpty else {
                throw CompilerIncomplete(stage: "validator", detail: "missing search directive")
            }
            let vars = ast.field("vars")?.elements ?? []
            for variable in vars {
                guard variable.type == "VarAssign", let name = variable.field("name")?.string,
                      let expression = variable.field("expr") else {
                    throw CompilerIncomplete(stage: "validator", detail: "malformed variable declaration")
                }
                symbols[name] = try substitute(expression)
            }
            var planned: [ParserValue] = []
            for statement in plans { planned.append(try compileStatement(statement)) }
            let render = ast.field("render")?.field("name") ?? .null
            var fields: [(String, ParserValue)] = [
                ("plans", .array(planned)), ("diagnostics", .array(diagnostics)),
                ("render", render), ("vars", .array(vars)),
                ("searchNamespaces", .array(searchOrder.map { .string($0) }))
            ]
            if let comments = ast.field("trailingComments") { fields.append(("trailingComments", comments)) }
            return .object(fields)
        }

        private mutating func compileStatement(_ statement: ParserValue) throws -> ParserValue {
            guard let calls = statement.field("chain")?.elements else {
                throw CompilerIncomplete(stage: "validator", detail: "branch or non-chain statement")
            }
            let write = statement.field("write")
            let write3d = statement.field("write3d")
            guard let write, write.type == "OutputRef", write3d?.isNull != false,
                  let writeName = write.field("name")?.string else {
                throw CompilerIncomplete(stage: "validator", detail: "chain requires a 2D output write")
            }
            var chain: [ParserValue] = []
            var current: Int? = nil
            try appendChainNodes(calls, current: &current, chain: &chain)
            let writeSurface = ParserValue.object([("kind", .string("output")), ("name", .string(writeName))])
            let final = current.map { ParserValue.number(Double($0)) } ?? .null
            var fields: [(String, ParserValue)] = [
                ("chain", .array(chain)), ("write", writeSurface),
                ("write3d", .null), ("final", final), ("states", .array([]))
            ]
            if let comments = statement.field("leadingComments") { fields.append(("leadingComments", comments)) }
            return .object(fields)
        }

        private mutating func appendChainNodes(_ calls: [ParserValue], current: inout Int?,
                                               chain: inout [ParserValue]) throws {
            for original in calls {
                switch original.type {
                case "Call":
                    let step = try compileCall(original, current: current, chain: &chain)
                    chain.append(step)
                    current = tempIndex - 1
                case "Read":
                    guard current == nil, let surface = toSurface(original.field("surface")) else {
                        throw CompilerIncomplete(stage: "validator", detail: "invalid read starter")
                    }
                    let args = ParserValue.object([("tex", surface)])
                    let step = makeStep(op: "_read", args: args, from: nil, builtin: true,
                                        comments: original.field("leadingComments"))
                    chain.append(step)
                    current = tempIndex - 1
                case "Write":
                    guard let input = current, let surface = toSurface(original.field("surface")) else {
                        throw CompilerIncomplete(stage: "validator", detail: "invalid write surface or input")
                    }
                    let args = ParserValue.object([("tex", surface)])
                    let step = makeStep(op: "_write", args: args, from: input, builtin: true,
                                        comments: original.field("leadingComments"))
                    chain.append(step)
                    current = tempIndex - 1
                case "Subchain":
                    for report in original.subchainArgumentDiagnostics {
                        var fields: [(String, ParserValue)] = [
                            ("code", .string(report.code)),
                            ("message", .string(report.message)),
                            ("severity", .string(report.severity)),
                            ("nodeId", original.field("id") ?? .undefined)
                        ]
                        if let location = report.location {
                            fields.append(("location", .object([
                                ("line", .number(Double(location.line))),
                                ("column", .number(Double(location.column)))
                            ])))
                        }
                        diagnostics.append(.object(fields))
                    }
                    guard let input = current, let body = original.field("body")?.elements else {
                        throw CompilerIncomplete(stage: "validator", detail: "subchain requires input and body")
                    }
                    let args = ParserValue.object([
                        ("name", original.field("name") ?? .null),
                        ("id", original.field("id") ?? .null)
                    ])
                    chain.append(makeStep(op: "_subchain_begin", args: args, from: input,
                                          builtin: true, comments: original.field("leadingComments")))
                    current = tempIndex - 1
                    try appendChainNodes(body, current: &current, chain: &chain)
                    chain.append(makeStep(op: "_subchain_end", args: args, from: current,
                                          builtin: true, comments: nil))
                    current = tempIndex - 1
                default:
                    throw CompilerIncomplete(stage: "validator", detail: "chain node \(original.type ?? "unknown")")
                }
            }
        }

        private mutating func compileCall(_ original: ParserValue, current: Int?,
                                          chain: inout [ParserValue]) throws -> ParserValue {
            guard let name = original.field("name")?.string,
                  let positional = original.field("args")?.elements else {
                throw CompilerIncomplete(stage: "validator", detail: "malformed call")
            }
            let namespace = original.field("namespace")
            var candidateNames: [String] = []
            if let resolved = namespace?.field("resolved")?.string { candidateNames.append("\(resolved).\(name)") }
            let effectiveSearch = namespace?.field("searchOrder")?.elements?.compactMap(\.string) ?? searchOrder
            candidateNames += effectiveSearch.map { "\($0).\(name)" }
            guard let opName = candidateNames.first(where: { registry.validatorOp($0) != nil }),
                  let op = registry.validatorOp(opName),
                  let specs = op.field("args")?.elements else {
                throw CompilerIncomplete(stage: "validator", detail: "unresolved effect \(name)")
            }
            let starter = registry.isStarter(opName)
            guard starter || current != nil else {
                throw CompilerIncomplete(stage: "validator", detail: "non-starter effect at chain root: \(opName)")
            }
            let from = starter ? nil : current
            let keyword = original.field("kwargs")
            var keywordFields = keyword?.fields ?? []
            let aliases = registry.paramAliases.mapEntries?.first {
                $0.key.stringValue == opName
            }?.value.objectFields ?? []
            for alias in aliases {
                guard let oldIndex = keywordFields.firstIndex(where: { $0.name == alias.name }),
                      let newName = alias.value.stringValue else { continue }
                let oldValue = keywordFields[oldIndex].value
                if !keywordFields.contains(where: { $0.name == newName }) {
                    keywordFields.append(ParserField(name: newName, value: oldValue))
                }
                keywordFields.remove(at: oldIndex)
                diagnostics.append(.object([
                    ("code", .string("S007")),
                    ("message", .string("param '\(alias.name)' is deprecated, use '\(newName)' instead. Aliases will be removed on 2026-09-01.")),
                    ("severity", .string("warning")),
                    ("nodeId", original.field("id") ?? .undefined),
                    ("identifier", .string(name))
                ]))
            }
            var args: [(String, ParserValue)] = []
            var argSources: [(String, ParserValue)] = []
            var seen: Set<String> = []
            for (index, spec) in specs.enumerated() {
                guard let key = spec.field("name")?.string,
                      let type = spec.field("type")?.string else {
                    throw CompilerIncomplete(stage: "validator", detail: "invalid argument spec for \(opName)")
                }
                let keywordNode = keywordFields.first(where: { $0.name == key })?.value
                let sourceNode = keywordNode ?? (index < positional.count ? positional[index] : nil)
                let node = try sourceNode.map { try substitute($0) }
                if keywordNode != nil { seen.insert(key) }
                let value = try resolveArgument(node, key: key, type: type, spec: spec,
                                                callName: name, opName: opName,
                                                argSources: &argSources, chain: &chain)
                args.append((key, value))
            }
            if let skip = keywordFields.first(where: { $0.name == "_skip" })?.value {
                args.append(("_skip", .bool(skip.type == "Boolean" && skip.field("value")?.bool == true)))
                seen.insert("_skip")
            }
            for field in keywordFields where !seen.contains(field.name) {
                throw CompilerIncomplete(stage: "validator", detail: "unknown argument \(field.name) for \(opName)")
            }
            let namespaceSnapshot = try snapshot(namespace)
            var step = makeStep(op: opName, args: .object(args), from: from,
                                builtin: false, comments: original.field("leadingComments"),
                                namespace: namespaceSnapshot)
            if keyword != nil { step = step.adding("rawKwargs", .object(keywordFields.map { ($0.name, $0.value) })) }
            if !argSources.isEmpty { step = step.adding("argSources", .object(argSources)) }
            return step
        }

        private mutating func resolveArgument(_ node: ParserValue?, key: String, type: String,
                                              spec: ParserValue, callName: String, opName: String,
                                              argSources: inout [(String, ParserValue)],
                                              chain: inout [ParserValue]) throws -> ParserValue {
            let fallback = spec.field("default") ?? .undefined
            guard let node else {
                if type == "member", let path = fallback.string {
                    let parts = path.split(separator: ".").map(String.init)
                    if let resolved = resolveEnum(parts) {
                        if let number = resolved.number { return .number(number) }
                        if let boolean = resolved.bool { return .number(boolean ? 1 : 0) }
                    }
                }
                if type == "surface", let name = fallback.string {
                    let kind = name == "none" ? "output" : "pipeline"
                    return .object([("kind", .string(kind)), ("name", .string(name))])
                }
                if type == "volume" || type == "geometry", let name = fallback.string {
                    return .object([("kind", .string(type == "volume" ? "vol" : "geo")),
                                    ("name", .string(name))])
                }
                return fallback
            }
            if node.type == "ArrayLiteral" {
                guard let elements = node.field("elements")?.elements else {
                    throw CompilerIncomplete(stage: "validator", detail: "malformed array argument")
                }
                var values: [ParserValue] = []
                for element in elements {
                    guard element.type == "Number", let number = element.field("value")?.number else {
                        throw CompilerIncomplete(stage: "validator", detail: "nonnumeric array argument \(key)")
                    }
                    values.append(.number(number))
                }
                argSources.append((key, .string("array")))
                return .array(values)
            }
            if type == "boolean" {
                if node.type == "Boolean", let value = node.field("value")?.bool { return .bool(value) }
                if node.type == "Number", let value = node.field("value")?.number { return .bool(value != 0) }
                if functionSource(node) != nil {
                    return .object([("fn", .taggedFunction("(state) => !!fn(state)"))])
                }
                if node.type == "Ident", let name = node.field("name")?.string,
                   Self.stateValues.contains(name), spec.field("choices")?.field(name) == nil {
                    return .object([("fn", .taggedFunction("(state) => !!state[key]"))])
                }
                throw CompilerIncomplete(stage: "validator", detail: "boolean expression for \(opName).\(key)")
            }
            if type == "surface" {
                let surfaceNode = node.type == "Read" ? node.field("surface") : node
                if let surface = toSurface(surfaceNode) { return surface }
                if node.type == "Call" {
                    let inline = try compileCall(node, current: nil, chain: &chain)
                    chain.append(inline)
                    guard let index = inline.field("temp")?.number else {
                        throw CompilerIncomplete(stage: "validator", detail: "inline surface has no temporary")
                    }
                    return .object([("kind", .string("temp")), ("index", .number(index))])
                }
                throw CompilerIncomplete(stage: "validator", detail: "surface expression for \(opName).\(key)")
            }
            if type == "volume" || type == "geometry" {
                guard let name = node.field("name")?.string else {
                    throw CompilerIncomplete(stage: "validator", detail: "volume/geometry expression for \(opName).\(key)")
                }
                return .object([("kind", .string(type == "volume" ? "vol" : "geo")),
                                ("name", .string(name))])
            }
            if type == "color" || type == "vec3" || type == "vec4" {
                if node.type == "Color", let value = node.field("value") {
                    if type == "vec3", let components = value.elements {
                        return .array(Array(components.prefix(3)))
                    }
                    return value
                }
                if (type == "vec3" || type == "vec4"), node.type == "Call",
                   node.field("name")?.string == type,
                   let components = node.field("args")?.elements,
                   components.count == (type == "vec3" ? 3 : 4) {
                    var values: [ParserValue] = []
                    for component in components {
                        guard component.type == "Number", let value = component.field("value")?.number else {
                            throw CompilerIncomplete(stage: "validator", detail: "nonnumeric \(type) component")
                        }
                        values.append(.number(value))
                    }
                    return .array(values)
                }
                if type == "color", node.type == "Number",
                   let number = node.field("value")?.number {
                    diagnostics.append(.object([
                        ("code", .string("S002")),
                        ("message", .string("Argument out of range for '\(key)' in \(callName)()")),
                        ("severity", .string("warning")),
                        ("nodeId", node.field("id") ?? .undefined),
                        ("identifier", .string(jsNumber(number)))
                    ]))
                    return fallback
                }
                throw CompilerIncomplete(stage: "validator", detail: "color/vector expression for \(opName).\(key)")
            }
            if type == "string" {
                if node.type == "String", let value = node.field("value") { return value }
                if node.type == "Ident", let name = node.field("name")?.string,
                   let choice = spec.field("choices")?.field(name) { return choice }
                throw CompilerIncomplete(stage: "validator", detail: "string expression for \(opName).\(key)")
            }
            if node.type == "Oscillator" { return try compileOscillator(node, depth: 0) }
            if let function = functionSource(node) {
                return .object([
                    ("fn", .taggedFunction(function)),
                    ("min", spec.field("min") ?? .undefined),
                    ("max", spec.field("max") ?? .undefined)
                ])
            }
            if node.type == "Ident", let name = node.field("name")?.string,
               Self.stateValues.contains(name), spec.field("choices")?.field(name) == nil {
                return .object([
                    ("fn", .taggedFunction("(state) => state[key]")),
                    ("min", spec.field("min") ?? .undefined),
                    ("max", spec.field("max") ?? .undefined),
                    ("_ast", node)
                ])
            }
            var value: Double
            if node.type == "Number", let numeric = node.field("value")?.number {
                value = numeric
            } else if node.type == "Boolean", let boolean = node.field("value")?.bool {
                value = boolean ? 1 : 0
            } else if node.type == "Member", let path = node.field("path")?.elements?.compactMap(\.string),
                      let resolved = resolveEnum(path), let numeric = resolved.number {
                value = numeric
            } else if node.type == "Ident", let name = node.field("name")?.string,
                      let enumPath = spec.field("enum")?.string,
                      let resolved = resolveEnum(enumPath.split(separator: ".").map(String.init) + [name]),
                      let numeric = resolved.number {
                value = numeric
            } else if node.type == "Ident", let name = node.field("name")?.string,
                      let choices = spec.field("choices"), let numeric = choices.field(name)?.number {
                value = numeric
            } else {
                throw CompilerIncomplete(stage: "validator", detail: "numeric expression for \(opName).\(key)")
            }
            let originalValue = value
            if let minimum = spec.field("min")?.number { value = max(value, minimum) }
            if let maximum = spec.field("max")?.number { value = min(value, maximum) }
            if value != originalValue {
                let identifier: String
                if node.type == "Member", let path = node.field("path")?.elements?.compactMap(\.string) {
                    identifier = path.joined(separator: ".")
                } else if let name = node.field("name")?.string {
                    identifier = name
                } else if let number = node.field("value")?.number, number != 0 {
                    identifier = jsNumber(number)
                } else {
                    identifier = "[\(node.type ?? "unknown")]"
                }
                diagnostics.append(.object([
                    ("code", .string("S002")),
                    ("message", .string("Argument out of range for '\(key)' in \(callName)() (got \(jsNumber(originalValue)), clamped to \(jsNumber(value)))")),
                    ("severity", .string("warning")),
                    ("nodeId", node.field("id") ?? .undefined),
                    ("identifier", .string(identifier))
                ]))
            }
            return .number(value)
        }

        private func jsNumber(_ value: Double) -> String {
            if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        }

        private func compileOscillator(_ node: ParserValue, depth: Int) throws -> ParserValue {
            guard depth <= 8 else {
                throw CompilerIncomplete(stage: "validator", detail: "automation nesting exceeds eight levels")
            }
            let oscTypeNode = node.field("oscType")
            var oscType = oscTypeNode?.field("value")?.number
            if oscType == nil, let path = oscTypeNode?.field("path")?.elements?.compactMap(\.string) {
                oscType = resolveEnum(path)?.number
            }
            guard let oscType, oscType.rounded() == oscType, (0...6).contains(oscType) else {
                throw CompilerIncomplete(stage: "validator", detail: "unsupported oscillator kind")
            }
            let minValue = try automationNumber(node.field("min"), depth: depth, clamp01: true)
            let maxValue = try automationNumber(node.field("max"), depth: depth, clamp01: true)
            let speed = try automationNumber(node.field("speed"), depth: depth, clamp01: false)
            let offset = try automationNumber(node.field("offset"), depth: depth, clamp01: false)
            let seed = try automationNumber(node.field("seed"), depth: depth, clamp01: false)
            var fields: [(String, ParserValue)] = [
                ("type", .string("Oscillator")), ("oscType", .number(oscType)),
                ("min", minValue), ("max", maxValue), ("speed", speed),
                ("offset", offset), ("seed", seed), ("_ast", node)
            ]
            if let variable = node.field("_varRef") { fields.append(("_varRef", variable)) }
            return .object(fields)
        }

        private func automationNumber(_ node: ParserValue?, depth: Int,
                                      clamp01: Bool) throws -> ParserValue {
            guard let node else {
                throw CompilerIncomplete(stage: "validator", detail: "missing oscillator field")
            }
            if node.type == "Oscillator" { return try compileOscillator(node, depth: depth + 1) }
            var value: Double
            if node.type == "Number", let number = node.field("value")?.number { value = number }
            else if node.type == "Boolean", let boolean = node.field("value")?.bool { value = boolean ? 1 : 0 }
            else if node.type == "Member", let path = node.field("path")?.elements?.compactMap(\.string),
                    let number = resolveEnum(path)?.number { value = number }
            else { throw CompilerIncomplete(stage: "validator", detail: "unsupported oscillator field") }
            guard value.isFinite else {
                throw CompilerIncomplete(stage: "validator", detail: "nonfinite oscillator field")
            }
            if clamp01 { value = max(0, min(1, value)) }
            return .number(value)
        }

        private func resolveEnum(_ path: [String]) -> ParserValue? {
            guard let first = path.first else { return nil }
            var value = symbols[first] ?? registry.mergedEnums.field(first)
            for part in path.dropFirst() { value = value?.field(part) }
            if value?.type == "Number" || value?.type == "Boolean" { return value?.field("value") }
            return value
        }

        private func substitute(_ node: ParserValue) throws -> ParserValue {
            guard node.type == "Ident", let name = node.field("name")?.string,
                  let symbol = symbols[name] else { return node }
            // Full cycle reporting is a later validator increment. Refuse a
            // self-reference rather than allowing recursive compilation.
            guard symbol != node else {
                throw CompilerIncomplete(stage: "validator", detail: "cyclic symbol \(name)")
            }
            return symbol.adding("_varRef", .string(name))
        }

        private func toSurface(_ node: ParserValue?) -> ParserValue? {
            guard let node, let type = node.type,
                  let name = node.field("name")?.string else { return nil }
            let kinds: [String: String] = [
                "OutputRef": "output", "SourceRef": "source", "XyzRef": "xyz",
                "VelRef": "vel", "RgbaRef": "rgba", "MeshRef": "mesh"
            ]
            if let kind = kinds[type] {
                return .object([("kind", .string(kind)), ("name", .string(name))])
            }
            if type == "Ident" && name == "none" {
                return .object([("kind", .string("output")), ("name", .string("none"))])
            }
            if type == "Ident" && ["time", "frame", "mouse", "resolution", "seed", "a"].contains(name) {
                return .object([("kind", .string("state")), ("name", .string(name))])
            }
            return nil
        }

        private func functionSource(_ node: ParserValue) -> String? {
            guard node.type == "Func", let source = node.field("src")?.string else { return nil }
            return "function anonymous(state\n) {\nwith(state){ return \(source); }\n}"
        }

        private func snapshot(_ namespace: ParserValue?) throws -> ParserValue? {
            guard let namespace, !namespace.isNull else { return nil }
            var call: [(String, ParserValue)] = [
                ("name", namespace.field("name") ?? .null),
                ("resolved", namespace.field("resolved") ?? .null),
                ("explicit", .bool(namespace.field("explicit")?.bool == true)),
                ("source", namespace.field("source") ?? .null)
            ]
            if let order = namespace.field("searchOrder") { call.append(("searchOrder", order)) }
            if namespace.field("fromOverride")?.bool == true { call.append(("fromOverride", .bool(true))) }
            var fields: [(String, ParserValue)] = [("call", .object(call))]
            if let resolved = namespace.field("resolved"), !resolved.isNull { fields.append(("resolved", resolved)) }
            return .object(fields)
        }

        private mutating func makeStep(op: String, args: ParserValue, from: Int?, builtin: Bool,
                                       comments: ParserValue?, namespace: ParserValue? = nil) -> ParserValue {
            let index = tempIndex
            tempIndex += 1
            var fields: [(String, ParserValue)] = [
                ("op", .string(op)), ("args", args),
                ("from", from.map { .number(Double($0)) } ?? .null),
                ("temp", .number(Double(index)))
            ]
            if builtin { fields.append(("builtin", .bool(true))) }
            if let namespace { fields.append(("namespace", namespace)) }
            if let comments { fields.append(("leadingComments", comments)) }
            return .object(fields)
        }
    }
}
