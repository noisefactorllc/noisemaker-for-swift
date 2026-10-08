import Foundation

public struct NativeCompilationStages {
    public let parsed: ParserValue
    public let validated: ParserValue
    public let expanded: GraphValue
    public let allocations: GraphValue
    public let graph: GraphValue
}

/// Native DSL compilation. Catalog and Portable definitions are packaged data;
/// this path does not invoke Node.js or the upstream JavaScript compiler.
public struct NoisemakerCompiler {
    public let registry: EffectRegistry

    public init(registry: EffectRegistry) { self.registry = registry }
    public init() throws { registry = try EffectRegistry.bundled() }

    public func compile(source: String) throws -> RenderGraph {
        let stages = try compileStages(source: source)
        let caseData = try makeRenderGraphInput(stages.graph)
        return try RenderGraph(exportedCaseData: caseData)
    }

    public func compileStages(source: String) throws -> NativeCompilationStages {
        let parsed = try NoisemakerParser.parse(source)
        let validated = try NoisemakerValidator.validate(parsed, registry: registry)
        let expanded = try NoisemakerExpander.expand(validated, registry: registry)
        guard let passes = expanded.field("passes")?.arrayValue,
              let programs = expanded.field("programs"),
              let textureSpecs = expanded.field("textureSpecs"),
              let surface = expanded.field("renderSurface") else {
            throw CompilerIncomplete(stage: "graph", detail: "malformed expansion result")
        }
        let allocations = try ResourceAllocator.allocate(passes: passes)
        let textures = try extractTextureSpecs(passes: passes, effectSpecs: textureSpecs)
        let graph: GraphValue = .object([
            GraphField(name: "id", value: .string(NoisemakerLexer.hashSource(source))),
            GraphField(name: "source", value: .string(source)),
            GraphField(name: "passes", value: .array(passes)),
            GraphField(name: "programs", value: programs),
            GraphField(name: "allocations", value: allocations),
            GraphField(name: "textures", value: textures),
            GraphField(name: "renderSurface", value: surface),
            GraphField(name: "mediaSteps", value: expanded.field("mediaSteps") ?? .array([])),
            GraphField(name: "compiledAt", value: .object([
                GraphField(name: "$type", value: .string("volatile-timestamp"))
            ]))
        ])
        return NativeCompilationStages(parsed: parsed, validated: validated,
                                       expanded: expanded, allocations: allocations, graph: graph)
    }

    private func extractTextureSpecs(passes: [GraphValue], effectSpecs: GraphValue) throws -> GraphValue {
        guard let effectFields = effectSpecs.objectFields else {
            throw CompilerIncomplete(stage: "graph", detail: "texture specs are not ordered fields")
        }
        var textures: [GraphMapEntry] = []
        var existing: Set<String> = []
        for item in effectFields {
            let raw = item.value
            var spec = OrderedObject()
            spec["width"] = truthy(raw.field("width")) ? raw.field("width") : .string("screen")
            spec["height"] = truthy(raw.field("height")) ? raw.field("height") : .string("screen")
            spec["format"] = truthy(raw.field("format")) ? raw.field("format") : .string("rgba16f")
            spec["usage"] = .array(["render", "sample", "copySrc", "copyDst"].map { .string($0) })
            if raw.field("is3D")?.boolValue == true {
                spec["depth"] = truthy(raw.field("depth")) ? raw.field("depth")
                    : (truthy(raw.field("width")) ? raw.field("width") : .number(64))
                spec["is3D"] = .bool(true)
                spec["usage"] = .array(["storage", "sample", "copySrc", "copyDst"].map { .string($0) })
                if truthy(raw.field("filter")) { spec["filter"] = raw.field("filter") }
            } else {
                if let mipmaps = raw.field("mipmaps"), !mipmaps.isUndefined { spec["mipmaps"] = mipmaps }
                if let persistent = raw.field("persistent"), !persistent.isUndefined { spec["persistent"] = persistent }
            }
            textures.append(GraphMapEntry(key: .string(item.name), value: spec.value))
            existing.insert(item.name)
        }
        for pass in passes {
            for output in pass.field("outputs")?.objectFields ?? [] {
                guard let name = output.value.stringValue else {
                    throw CompilerIncomplete(stage: "graph", detail: "non-string output texture")
                }
                if name.hasPrefix("global_") || !existing.insert(name).inserted { continue }
                var spec = OrderedObject()
                spec["width"] = .string("screen")
                spec["height"] = .string("screen")
                spec["format"] = .string("rgba16f")
                spec["usage"] = .array(["render", "sample", "copySrc", "copyDst"].map { .string($0) })
                textures.append(GraphMapEntry(key: .string(name), value: spec.value))
            }
        }
        return .map(textures)
    }

    private func truthy(_ value: GraphValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .undefined, .null: return false
        case .bool(let bool): return bool
        case .number(let number): return number != 0 && !number.isNaN
        case .string(let string): return !string.isEmpty
        default: return true
        }
    }

    func makeRenderGraphInput(_ graph: GraphValue) throws -> Data {
        guard let programs = graph.field("programs")?.objectFields else {
            throw CompilerIncomplete(stage: "graph", detail: "missing programs")
        }
        var records: [String: Any] = [:]
        for program in programs {
            guard let original = program.value.field("wgsl")?.stringValue else {
                throw CompilerIncomplete(stage: "graph", detail: "program \(program.name) lacks WGSL")
            }
            let resolved = try injectDefines(into: original, definitions: program.value.field("defines"))
            let entries = entryPoints(in: resolved)
            records[program.name] = ["originalWGSL": original, "resolvedWGSL": resolved,
                                     "entryPoints": entries]
        }
        let caseFile: [String: Any] = ["stages": ["graph": graph.taggedValue()], "programs": records]
        return try StableTaggedJSON.encode(caseFile)
    }

    private func injectDefines(into source: String, definitions: GraphValue?) throws -> String {
        var prefix = ""
        for field in definitions?.objectFields ?? [] {
            let value = field.value
            if let bool = value.boolValue {
                prefix += "const \(field.name): bool = \(bool ? "true" : "false");\n"
            } else if let number = value.numberValue {
                let numeric: String
                if number.rounded() == number && abs(number) < 1e15 { numeric = String(Int(number)) }
                else { numeric = String(number) }
                prefix += "const \(field.name): \(number.rounded() == number ? "i32" : "f32") = \(numeric);\n"
            } else if let string = value.stringValue {
                prefix += "const \(field.name) = \(string);\n"
            } else {
                throw CompilerIncomplete(stage: "graph", detail: "non-scalar program define \(field.name)")
            }
        }
        return prefix + source
    }

    private func entryPoints(in source: String) -> [[String: String]] {
        let pattern = #"@(vertex|fragment|compute)\s+(?:@\w+(?:\([^)]*\))?\s+)*fn\s+(\w+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: text.length))
        return matches.map { match in
            ["stage": text.substring(with: match.range(at: 1)),
             "name": text.substring(with: match.range(at: 2))]
        }
    }
}
