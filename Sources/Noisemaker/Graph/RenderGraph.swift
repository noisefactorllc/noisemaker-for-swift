import Foundation

public struct GraphNamedValue {
    public let key: String
    public let value: GraphValue
}

public struct GraphProgram {
    public let id: String
    public let raw: GraphValue
    public let resolvedWGSL: String
    public let fragmentEntryPoint: String
    public let stage: TintStage
    public let defaultEntryPoint: String
}

public struct GraphPass {
    public let id: String
    public let program: String
    public let raw: GraphValue
    public let inputs: [GraphNamedValue]
    public let outputs: [GraphNamedValue]
    public let uniforms: [GraphField]
    public let entryPoint: String
}

public struct GraphTexture {
    public let key: String
    public let raw: GraphValue
    public let format: String
    public let width: GraphDimension
    public let height: GraphDimension
}

public struct RenderGraph {
    public let raw: GraphValue
    public let id: String
    public let source: String
    public let passes: [GraphPass]
    public let programs: [String: GraphProgram]
    public let allocations: [GraphNamedValue]
    public let textures: [GraphTexture]
    public let renderSurface: String
    let dimensionParameters: [String: Double]

    public init(exportedCaseData data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data)
        guard let caseFile = any as? [String: Any],
              let stages = caseFile["stages"] as? [String: Any],
              let encodedGraph = stages["graph"] else {
            throw GraphDiagnostic.invalid("expected stages.graph in exported case")
        }
        let graph = try GraphValue.decode(encodedGraph)
        guard let graphFields = graph.objectFields else {
            throw GraphDiagnostic.invalid("graph must be a tagged object")
        }
        try Self.validateFields(graphFields, allowed: [
            "id", "source", "passes", "programs", "allocations", "textures", "renderSurface", "mediaSteps", "compiledAt"
        ], context: "graph")
        guard let id = graph.field("id")?.stringValue,
              let source = graph.field("source")?.stringValue,
              let renderSurface = graph.field("renderSurface")?.stringValue,
              let passValues = graph.field("passes")?.arrayValue,
              let programFields = graph.field("programs")?.objectFields else {
            throw GraphDiagnostic.invalid("graph id, source, passes, programs or renderSurface missing")
        }
        guard graph.field("mediaSteps")?.arrayValue?.isEmpty == true else {
            throw GraphDiagnostic.unsupported("mediaSteps are not implemented by the task-2 renderer")
        }
        let textureValues = try Self.namedMap(graph.field("textures"), "textures")
        let allocations = try Self.namedMap(graph.field("allocations"), "allocations")
        let casePrograms = caseFile["programs"] as? [String: [String: Any]] ?? [:]
        var programs: [String: GraphProgram] = [:]
        for field in programFields {
            guard let spec = field.value.objectFields else {
                throw GraphDiagnostic.invalid("program \(field.name) must be an object")
            }
            // Graphs retain non-executed templates, but only a pass-referenced
            // program is compiled or required to fit this renderer's subset.
            guard passValues.contains(where: { $0.field("program")?.stringValue == field.name }) else { continue }
            try Self.validateFields(spec, allowed: ["wgsl", "uniformLayout", "defines", "fragment", "fragmentEntryPoint", "computeEntryPoint"], context: "program \(field.name)")
            guard let original = field.value.field("wgsl")?.stringValue else {
                throw GraphDiagnostic.invalid("program \(field.name) lacks WGSL")
            }
            guard let resolved = casePrograms[field.name]?["resolvedWGSL"] as? String else {
                throw GraphDiagnostic.missing("resolved WGSL for program \(field.name)")
            }
            if resolved != original && casePrograms[field.name]?["originalWGSL"] as? String != original {
                throw GraphDiagnostic.invalid("program \(field.name) exported source differs from graph")
            }
            guard let entries = casePrograms[field.name]?["entryPoints"] as? [[String: String]] else {
                throw GraphDiagnostic.missing("entry points for program \(field.name)")
            }
            let selected = entries.first(where: { $0["stage"] == "fragment" })
                ?? entries.first(where: { $0["stage"] == "compute" })
            guard let selected, let selectedName = selected["name"],
                  let selectedStage = selected["stage"] else {
                throw GraphDiagnostic.unsupported("program \(field.name) lacks a render or compute entry point")
            }
            let stage: TintStage = selectedStage == "fragment" ? .fragment : .compute
            let defaultEntryPoint = stage == .fragment
                ? (field.value.field("fragmentEntryPoint")?.stringValue ?? selectedName)
                : (field.value.field("computeEntryPoint")?.stringValue ?? selectedName)
            programs[field.name] = GraphProgram(id: field.name, raw: field.value,
                resolvedWGSL: resolved,
                fragmentEntryPoint: field.value.field("fragmentEntryPoint")?.stringValue ?? "main",
                stage: stage, defaultEntryPoint: defaultEntryPoint)
        }
        let passes = try passValues.enumerated().map { index, value -> GraphPass in
            guard let fields = value.objectFields else {
                throw GraphDiagnostic.invalid("pass \(index) is not an object")
            }
            try Self.validateFields(fields, allowed: [
                "id", "program", "entryPoint", "drawMode", "drawBuffers", "count", "countUniform",
                "repeat", "blend", "conditions", "workgroups", "storageBuffers", "storageTextures",
                "name", "type", "clear", "viewport", "samplerTypes", "inputs", "outputs", "uniforms",
                "effectKey", "effectFunc", "effectNamespace", "nodeId", "stepIndex", "uniformSpecs",
                "uniformAliases", "scopedParams"
            ], context: "pass \(index)")
            for key in ["drawMode", "count", "countUniform", "repeat", "blend",
                        "conditions", "workgroups", "storageBuffers", "storageTextures", "viewport",
                        "samplerTypes", "uniformAliases", "scopedParams"] {
                if let candidate = value.field(key), !candidate.isUndefined {
                    throw GraphDiagnostic.unsupported("pass \(index) uses \(key)")
                }
            }
            if let type = value.field("type"), !type.isUndefined,
               type.stringValue != "render", type.stringValue != "compute" {
                throw GraphDiagnostic.unsupported("pass \(index) type \(String(describing: type.stringValue))")
            }
            if let clear = value.field("clear"), !clear.isUndefined,
               case .bool(true) = clear {} else if let clear = value.field("clear"), !clear.isUndefined {
                throw GraphDiagnostic.unsupported("pass \(index) requires load semantics for clear=\(clear)")
            }
            guard let id = value.field("id")?.stringValue,
                  let program = value.field("program")?.stringValue,
                  programs[program] != nil else {
                throw GraphDiagnostic.invalid("pass \(index) lacks a referenced program")
            }
            let inputs = try Self.namedObject(value.field("inputs"), "pass \(id) inputs")
            let outputs = try Self.namedObject(value.field("outputs"), "pass \(id) outputs")
            guard (1...8).contains(outputs.count), inputs.count <= 16 else {
                throw GraphDiagnostic.unsupported("pass \(id) attachment or input count exceeds task-3 subset")
            }
            if let drawBuffers = value.field("drawBuffers"), !drawBuffers.isUndefined {
                guard let count = drawBuffers.numberValue, count == Double(outputs.count),
                      count >= 1, count <= 8 else {
                    throw GraphDiagnostic.unsupported("pass \(id) drawBuffers differs from ordered outputs")
                }
            }
            guard let uniforms = value.field("uniforms")?.objectFields else {
                throw GraphDiagnostic.invalid("pass \(id) lacks ordered uniforms")
            }
            let requestedEntry = value.field("entryPoint")?.stringValue
            let entryPoint = requestedEntry ?? programs[program]!.defaultEntryPoint
            return GraphPass(id: id, program: program, raw: value, inputs: inputs,
                outputs: outputs, uniforms: uniforms, entryPoint: entryPoint)
        }
        let textures = try textureValues.map { item -> GraphTexture in
            guard let fields = item.value.objectFields else {
                throw GraphDiagnostic.invalid("texture \(item.key) spec is not an object")
            }
            try Self.validateFields(fields, allowed: ["width", "height", "format", "usage", "mipmaps", "persistent"], context: "texture \(item.key)")
            guard let rawWidth = item.value.field("width"),
                  let rawHeight = item.value.field("height"),
                  let format = item.value.field("format")?.stringValue,
                  ["rgba16f", "rgba8", "rgba8unorm", "rgba32f"].contains(format) else {
                throw GraphDiagnostic.unsupported("texture \(item.key) dimensions or format")
            }
            let width = try GraphDimension.decode(rawWidth, context: "texture \(item.key) width")
            let height = try GraphDimension.decode(rawHeight, context: "texture \(item.key) height")
            if let mips = item.value.field("mipmaps"), !mips.isUndefined,
               case .bool(false) = mips {} else if let mips = item.value.field("mipmaps"), !mips.isUndefined {
                throw GraphDiagnostic.unsupported("texture \(item.key) mipmaps")
            }
            if let persistent = item.value.field("persistent"), !persistent.isUndefined,
               case .bool(false) = persistent {} else if let persistent = item.value.field("persistent"), !persistent.isUndefined {
                throw GraphDiagnostic.unsupported("texture \(item.key) persistence")
            }
            guard let usage = item.value.field("usage")?.arrayValue,
                  usage.allSatisfy({ value in
                      guard let name = value.stringValue else { return false }
                      return ["render", "sample", "copySrc", "copyDst"].contains(name)
                  }) else {
                throw GraphDiagnostic.unsupported("texture \(item.key) usage")
            }
            return GraphTexture(key: item.key, raw: item.value, format: format,
                width: width, height: height)
        }
        let finalTarget = "global_\(renderSurface)"
        guard passes.last?.outputs.first?.value.stringValue == finalTarget else {
            throw GraphDiagnostic.unsupported("last pass does not write renderSurface \(renderSurface)")
        }
        let declared = Set(textures.map(\.key))
        guard declared.count == textures.count,
              Set(allocations.map(\.key)).count == allocations.count,
              declared == Set(allocations.map(\.key)),
              allocations.allSatisfy({ $0.value.stringValue != nil }) else {
            throw GraphDiagnostic.unsupported("texture allocations differ from declared textures")
        }
        var produced = Set<String>()
        for (index, pass) in passes.enumerated() {
            let outputNames = Set(pass.outputs.compactMap { $0.value.stringValue })
            guard outputNames.count == pass.outputs.count,
                  outputNames.allSatisfy({ declared.contains($0) || $0 == finalTarget }) else {
                throw GraphDiagnostic.unsupported("pass \(pass.id) targets undeclared or duplicate textures")
            }
            for input in pass.inputs {
                guard let source = input.value.stringValue,
                      !source.hasPrefix("global_"), !outputNames.contains(source),
                      produced.contains(source) else {
                    throw GraphDiagnostic.unsupported("pass \(pass.id) reads feedback or an unproduced texture")
                }
            }
            for target in outputNames {
                guard produced.insert(target).inserted else {
                    throw GraphDiagnostic.unsupported("pass \(pass.id) rewrites a texture without lifetime analysis")
                }
                if target == finalTarget && index != passes.count - 1 {
                    throw GraphDiagnostic.unsupported("render surface output must be last")
                }
            }
        }
        // Physical allocation reuse is an optimization. This executor assigns each
        // logical texture its own target until completion-aware pooling is qualified.
        self.raw = graph
        self.id = id
        self.source = source
        self.passes = passes
        self.programs = programs
        self.allocations = allocations
        self.textures = textures
        self.renderSurface = renderSurface
        self.dimensionParameters = try Self.dimensionParameters(passes: passes, textures: textures)
    }

    func validateDimensions(for size: RenderSize) throws {
        var resolved: [String: RenderSize] = [:]
        for texture in textures {
            resolved[texture.key] = try RenderSize(
                width: texture.width.resolve(screen: size.width, parameters: dimensionParameters),
                height: texture.height.resolve(screen: size.height, parameters: dimensionParameters))
        }
        for pass in passes where programs[pass.program]?.stage == .compute {
            guard let outputName = pass.outputs.first?.value.stringValue,
                  let output = resolved[outputName], output == size else {
                throw GraphDiagnostic.unsupported("pass \(pass.id) compute output must be screen-sized for upstream buffer indexing")
            }
            for input in pass.inputs {
                guard let inputName = input.value.stringValue,
                      resolved[inputName] == output else {
                    throw GraphDiagnostic.unsupported("pass \(pass.id) compute input/output dimensions differ")
                }
            }
        }
    }

    private static func dimensionParameters(passes: [GraphPass], textures: [GraphTexture]) throws -> [String: Double] {
        var names = Set<String>()
        for texture in textures {
            for dimension in [texture.width, texture.height] {
                switch dimension {
                case .parameter(let name, _, _, _), .screenDivide(let name, _): names.insert(name)
                default: break
                }
            }
        }
        var result: [String: Double] = [:]
        for pass in passes {
            for field in pass.uniforms where names.contains(field.name) {
                guard let number = field.value.numberValue, number.isFinite else {
                    throw GraphDiagnostic.unsupported("texture dimension parameter \(field.name) is not a finite number")
                }
                if let prior = result[field.name], prior != number {
                    throw GraphDiagnostic.unsupported("texture dimension parameter \(field.name) varies by pass")
                }
                result[field.name] = number
            }
        }
        return result
    }

    private static func validateFields(_ fields: [GraphField], allowed: Set<String>, context: String) throws {
        var names = Set<String>()
        for field in fields {
            guard names.insert(field.name).inserted else { throw GraphDiagnostic.invalid("duplicate \(context) field \(field.name)") }
            guard allowed.contains(field.name) else { throw GraphDiagnostic.unsupported("unknown \(context) field \(field.name)") }
        }
    }

    private static func namedObject(_ value: GraphValue?, _ context: String) throws -> [GraphNamedValue] {
        guard let fields = value?.objectFields else { throw GraphDiagnostic.invalid("\(context) is not an object") }
        return try fields.map { field in
            guard field.value.stringValue != nil else {
                throw GraphDiagnostic.unsupported("\(context) \(field.name) is not a texture name")
            }
            return GraphNamedValue(key: field.name, value: field.value)
        }
    }

    private static func namedMap(_ value: GraphValue?, _ context: String) throws -> [GraphNamedValue] {
        guard let entries = value?.mapEntries else { throw GraphDiagnostic.invalid("\(context) is not an ordered Map") }
        return try entries.map { item in
            guard let key = item.key.stringValue else { throw GraphDiagnostic.invalid("\(context) has non-string key") }
            return GraphNamedValue(key: key, value: item.value)
        }
    }
}
