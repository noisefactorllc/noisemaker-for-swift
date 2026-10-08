import Foundation

private extension GraphValue {
    var isNullish: Bool {
        switch self {
        case .null, .undefined: return true
        default: return false
        }
    }
}

public struct GraphNamedValue {
    public let key: String
    public let value: GraphValue
}

public struct GraphProgram {
    public let id: String
    public let raw: GraphValue
    public let resolvedWGSL: String
    public let fragmentEntryPoint: String
    public let vertexEntryPoint: String?
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
    public let repeatCount: Int
    let conditions: GraphConditions?

    init(id: String, program: String, raw: GraphValue, inputs: [GraphNamedValue],
         outputs: [GraphNamedValue], uniforms: [GraphField], entryPoint: String,
         repeatCount: Int, conditions: GraphConditions? = nil) {
        self.id = id
        self.program = program
        self.raw = raw
        self.inputs = inputs
        self.outputs = outputs
        self.uniforms = uniforms
        self.entryPoint = entryPoint
        self.repeatCount = repeatCount
        self.conditions = conditions
    }
}

struct GraphPredicate {
    let uniform: String
    let equals: GraphValue
}

struct GraphConditions {
    let skipIf: [GraphPredicate]
    let runIf: [GraphPredicate]

    func shouldSkip(pass: GraphPass, frame: FrameState) -> Bool {
        func matches(_ condition: GraphPredicate) -> Bool {
            let raw = pass.uniforms.first(where: { $0.name == condition.uniform })?.value
            let resolved: GraphValue
            if let raw, !raw.isNullish {
                resolved = raw
            } else {
                switch condition.uniform {
                case "frame": resolved = .number(Double(frame.frameIndex))
                case "time": resolved = .number(frame.time)
                case "deltaTime": resolved = .number(frame.delta)
                default: return false
                }
            }
            switch (resolved, condition.equals) {
            case (.number(let a), .number(let b)): return a == b
            case (.bool(let a), .bool(let b)): return a == b
            case (.string(let a), .string(let b)): return a == b
            case (.null, .null), (.undefined, .undefined): return true
            default: return false
            }
        }
        return skipIf.contains(where: matches) || !runIf.allSatisfy(matches)
    }
}

public struct GraphTexture {
    public let key: String
    public let raw: GraphValue
    public let format: String
    public let width: GraphDimension
    public let height: GraphDimension
    public let depth: GraphDimension?
    public let is3D: Bool
    public let filter: String?
    public let mipmaps: Bool
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
    let globalSurfaceNames: [String]
    let conservativePersistentTextureNames: [String]
    var persistentTextureNames: [String]
    public let externalTextureNames: [String]
    public let mediaSteps: [GraphMediaStep]

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
        let mediaSteps = try GraphMediaStep.decode(graph.field("mediaSteps"))
        let mediaNames = Set(mediaSteps.map(\.textureId))
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
            try Self.validateFields(spec, allowed: ["wgsl", "uniformLayout", "defines", "fragment", "fragmentEntryPoint", "vertexEntryPoint", "computeEntryPoint"], context: "program \(field.name)")
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
            let detectedVertex = entries.first(where: { $0["stage"] == "vertex" })?["name"]
            let vertexEntry = field.value.field("vertexEntryPoint")?.stringValue ?? detectedVertex
            guard vertexEntry == nil || entries.contains(where: {
                $0["stage"] == "vertex" && $0["name"] == vertexEntry
            }) else {
                throw GraphDiagnostic.unsupported("program \(field.name) vertex entry point differs from WGSL")
            }
            let defaultEntryPoint = stage == .fragment
                ? (field.value.field("fragmentEntryPoint")?.stringValue ?? selectedName)
                : (field.value.field("computeEntryPoint")?.stringValue ?? selectedName)
            programs[field.name] = GraphProgram(id: field.name, raw: field.value,
                resolvedWGSL: resolved,
                fragmentEntryPoint: field.value.field("fragmentEntryPoint")?.stringValue ?? "main",
                vertexEntryPoint: vertexEntry,
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
                "uniformAliases", "scopedParams", "inheritsVolumeSize"
            ], context: "pass \(index)")
            if let buffers = value.field("storageBuffers"), !buffers.isUndefined {
                throw GraphDiagnostic.unsupported("pass \(index) uses storageBuffers")
            }
            let storageTextures = value.field("storageTextures")
            let workgroups = value.field("workgroups")
            let hasStorage = storageTextures?.isUndefined == false
            if hasStorage {
                guard programs[value.field("program")?.stringValue ?? ""]?.stage == .compute,
                      let entries = storageTextures?.objectFields, entries.count == 1,
                      entries[0].value.stringValue?.isEmpty == false,
                      let groups = workgroups?.arrayValue, groups.count == 3,
                      groups.allSatisfy({ group in
                          guard let count = group.numberValue else { return false }
                          return count.isFinite && count >= 1 && count <= 65_535 &&
                              count.rounded(.towardZero) == count
                      }) else {
                    throw GraphDiagnostic.unsupported("pass \(index) requires one 3D storage output and three numeric workgroups")
                }
            } else if let workgroups, !workgroups.isUndefined {
                throw GraphDiagnostic.unsupported("pass \(index) uses workgroups without storageTextures")
            }
            if let samplers = value.field("samplerTypes"), !samplers.isUndefined {
                guard let fields = samplers.objectFields, fields.allSatisfy({
                    ["default", "nearest", "repeat", "mipmap"].contains($0.value.stringValue ?? "")
                }) else {
                    throw GraphDiagnostic.unsupported("pass \(index) invalid samplerTypes")
                }
            }
            if let type = value.field("type"), !type.isUndefined,
               type.stringValue != "render", type.stringValue != "compute" {
                throw GraphDiagnostic.unsupported("pass \(index) type \(String(describing: type.stringValue))")
            }
            if let clear = value.field("clear"), !clear.isUndefined {
                guard case .bool = clear else {
                    throw GraphDiagnostic.unsupported("pass \(index) clear must be boolean")
                }
            }
            if let blend = value.field("blend"), !blend.isUndefined {
                switch blend {
                case .bool: break
                case .array(let factors):
                    guard factors.count == 2, factors.allSatisfy({ $0.stringValue != nil }) else {
                        throw GraphDiagnostic.unsupported("pass \(index) blend requires two factors")
                    }
                default: throw GraphDiagnostic.unsupported("pass \(index) blend is not supported")
                }
            }
            if let viewport = value.field("viewport"), !viewport.isUndefined {
                guard let fields = viewport.objectFields,
                      Set(fields.map(\.name)).isSubset(of: ["x", "y", "w", "h", "width", "height"]) else {
                    throw GraphDiagnostic.unsupported("pass \(index) viewport specification")
                }
                let numericBox = ["x", "y", "w", "h"].allSatisfy {
                    viewport.field($0)?.numberValue?.isFinite == true
                }
                if numericBox {
                    guard viewport.field("x")!.numberValue! >= 0,
                          viewport.field("y")!.numberValue! >= 0,
                          viewport.field("w")!.numberValue! > 0,
                          viewport.field("h")!.numberValue! > 0 else {
                        throw GraphDiagnostic.unsupported("pass \(index) invalid numeric viewport")
                    }
                } else {
                    for field in fields {
                        if field.name == "x" || field.name == "y",
                           field.value.numberValue == 0 { continue }
                        _ = try GraphDimension.decode(field.value,
                            context: "pass \(index) viewport \(field.name)")
                    }
                }
            }
            guard let id = value.field("id")?.stringValue,
                  let program = value.field("program")?.stringValue,
                  programs[program] != nil else {
                throw GraphDiagnostic.invalid("pass \(index) lacks a referenced program")
            }
            let drawMode = value.field("drawMode")
            if let drawMode, !drawMode.isUndefined {
                guard let name = drawMode.stringValue,
                      ["points", "billboards", "triangles"].contains(name),
                      programs[program]?.stage == .fragment,
                      programs[program]?.vertexEntryPoint != nil else {
                    throw GraphDiagnostic.unsupported("pass \(id) drawMode or vertex entry point")
                }
            }
            if let count = value.field("count"), !count.isUndefined {
                let numeric = count.numberValue.map { $0.isFinite && $0 >= 0 &&
                    $0.rounded(.towardZero) == $0 && $0 <= 16_000_000 } ?? false
                let names = drawMode?.stringValue == "triangles"
                    ? ["auto", "input"] : ["auto", "screen", "input"]
                guard drawMode?.stringValue != nil,
                      numeric || names.contains(count.stringValue ?? "") else {
                    throw GraphDiagnostic.unsupported("pass \(id) draw count")
                }
            }
            if let countUniform = value.field("countUniform"), !countUniform.isUndefined {
                guard drawMode?.stringValue == "triangles",
                      countUniform.stringValue?.isEmpty == false else {
                    throw GraphDiagnostic.unsupported("pass \(id) countUniform")
                }
            }
            let inputs = try Self.namedObject(value.field("inputs"), "pass \(id) inputs")
            let outputs = try Self.namedObject(value.field("outputs"), "pass \(id) outputs")
            guard (hasStorage ? outputs.isEmpty : (1...8).contains(outputs.count)),
                  inputs.count <= 16 else {
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
            let conditions: GraphConditions?
            if let rawConditions = value.field("conditions"), !rawConditions.isUndefined {
                guard let fields = rawConditions.objectFields,
                      Set(fields.map(\.name)).isSubset(of: ["skipIf", "runIf"]) else {
                    throw GraphDiagnostic.unsupported("pass \(id) conditions")
                }
                func predicates(_ key: String) throws -> [GraphPredicate] {
                    guard let raw = rawConditions.field(key) else { return [] }
                    guard let entries = raw.arrayValue else {
                        throw GraphDiagnostic.unsupported("pass \(id) \(key) conditions")
                    }
                    return try entries.map { entry in
                        guard let fields = entry.objectFields, fields.count == 2,
                              Set(fields.map(\.name)) == ["uniform", "equals"],
                              let name = entry.field("uniform")?.stringValue,
                              (uniforms.contains(where: { $0.name == name }) ||
                               ["frame", "time", "deltaTime"].contains(name)),
                              let expected = entry.field("equals") else {
                            throw GraphDiagnostic.unsupported("pass \(id) \(key) predicate")
                        }
                        switch expected {
                        case .number(let n) where n.isFinite: break
                        case .bool, .string, .null, .undefined: break
                        default: throw GraphDiagnostic.unsupported("pass \(id) \(key) comparison")
                        }
                        return GraphPredicate(uniform: name, equals: expected)
                    }
                }
                conditions = try GraphConditions(skipIf: predicates("skipIf"),
                    runIf: predicates("runIf"))
            } else {
                conditions = nil
            }
            if let aliases = value.field("uniformAliases"), !aliases.isUndefined {
                guard let fields = aliases.objectFields,
                      fields.allSatisfy({ field in
                          guard let source = field.value.stringValue else { return false }
                          return !source.isEmpty && uniforms.contains(where: { $0.name == field.name })
                      }) else {
                    throw GraphDiagnostic.unsupported("pass \(id) unresolved uniformAliases")
                }
            }
            if let scoped = value.field("scopedParams"), !scoped.isUndefined {
                guard let fields = scoped.objectFields, fields.allSatisfy({ field in
                    guard let scopedName = field.value.stringValue else { return false }
                    return uniforms.contains(where: { $0.name == field.name }) &&
                        uniforms.contains(where: { $0.name == scopedName })
                }) else {
                    throw GraphDiagnostic.unsupported("pass \(id) unresolved scopedParams")
                }
            }
            if let inherited = value.field("inheritsVolumeSize"), !inherited.isUndefined {
                guard case .bool(true) = inherited,
                      uniforms.contains(where: { $0.name == "volumeSize" }) else {
                    throw GraphDiagnostic.unsupported("pass \(id) invalid volumeSize inheritance")
                }
            }
            let repeatCount: Int
            if let repeated = value.field("repeat"), !repeated.isUndefined {
                let resolved: Double?
                switch repeated {
                case .number(let number): resolved = number
                case .string(let uniform): resolved = uniforms.first(where: { $0.name == uniform })?.value.numberValue
                default: resolved = nil
                }
                guard let resolved, resolved.isFinite, resolved >= 0, resolved <= 256 else {
                    throw GraphDiagnostic.unsupported("pass \(id) repeat count is not a bounded number")
                }
                repeatCount = max(1, Int(resolved.rounded(.down)))
            } else {
                repeatCount = 1
            }
            let requestedEntry = value.field("entryPoint")?.stringValue
            let entryPoint = requestedEntry ?? programs[program]!.defaultEntryPoint
            return GraphPass(id: id, program: program, raw: value, inputs: inputs,
                outputs: outputs, uniforms: uniforms, entryPoint: entryPoint,
                repeatCount: repeatCount, conditions: conditions)
        }
        let textures = try textureValues.map { item -> GraphTexture in
            guard let fields = item.value.objectFields else {
                throw GraphDiagnostic.invalid("texture \(item.key) spec is not an object")
            }
            let is3D: Bool
            if let flag = item.value.field("is3D"), !flag.isUndefined {
                guard let value = flag.boolValue else {
                    throw GraphDiagnostic.unsupported("texture \(item.key) is3D must be boolean")
                }
                is3D = value
            } else { is3D = false }
            let allowed: Set<String> = is3D
                ? ["width", "height", "depth", "format", "usage", "is3D", "filter"]
                : ["width", "height", "format", "usage", "mipmaps", "persistent", "is3D"]
            try Self.validateFields(fields, allowed: allowed, context: "texture \(item.key)")
            guard let rawWidth = item.value.field("width"),
                  let rawHeight = item.value.field("height"),
                  let format = item.value.field("format")?.stringValue,
                  ["rgba16f", "rgba16float", "rgba8", "rgba8unorm", "rgba32f", "rgba32float",
                   "r8", "r8unorm", "r16f", "r16float", "r32f", "r32float"].contains(format) else {
                throw GraphDiagnostic.unsupported("texture \(item.key) dimensions or format")
            }
            let width = try GraphDimension.decode(rawWidth, context: "texture \(item.key) width")
            let height = try GraphDimension.decode(rawHeight, context: "texture \(item.key) height")
            let depth: GraphDimension?
            let filter: String?
            let mipmaps: Bool
            if is3D {
                guard let rawDepth = item.value.field("depth") else {
                    throw GraphDiagnostic.unsupported("texture \(item.key) lacks 3D depth")
                }
                depth = try GraphDimension.decode(rawDepth, context: "texture \(item.key) depth")
                let value = item.value.field("filter")?.stringValue ?? "linear"
                guard ["nearest", "linear"].contains(value) else {
                    throw GraphDiagnostic.unsupported("texture \(item.key) 3D filter")
                }
                filter = value
                mipmaps = false
            } else {
                depth = nil
                filter = nil
                if let mips = item.value.field("mipmaps"), !mips.isUndefined {
                    guard let value = mips.boolValue else {
                        throw GraphDiagnostic.unsupported("texture \(item.key) mipmaps must be boolean")
                    }
                    mipmaps = value
                } else { mipmaps = false }
                if mipmaps && item.key.hasPrefix("global_") {
                    throw GraphDiagnostic.unsupported("mipmapped global surface \(item.key)")
                }
                if let persistent = item.value.field("persistent"), !persistent.isUndefined,
                   case .bool = persistent {} else if let persistent = item.value.field("persistent"), !persistent.isUndefined {
                    throw GraphDiagnostic.unsupported("texture \(item.key) persistence must be boolean")
                }
            }
            let usageNames = item.value.field("usage")?.arrayValue?.compactMap(\.stringValue)
            let expectedUsage = is3D
                ? ["storage", "sample", "copySrc", "copyDst"]
                : ["render", "sample", "copySrc", "copyDst"]
            guard usageNames == expectedUsage else {
                throw GraphDiagnostic.unsupported("texture \(item.key) usage")
            }
            return GraphTexture(key: item.key, raw: item.value, format: format,
                width: width, height: height, depth: depth, is3D: is3D,
                filter: filter, mipmaps: mipmaps)
        }
        guard mediaSteps.allSatisfy({$0.isReferenced(by:passes)}) else {
            throw GraphDiagnostic.invalid("mediaSteps must identify an input of their declared effect step")
        }
        let finalTarget = "global_\(renderSurface)"
        guard passes.contains(where: { pass in
            pass.outputs.contains(where: { $0.value.stringValue == finalTarget })
        }) else {
            throw GraphDiagnostic.unsupported("no pass writes renderSurface \(renderSurface)")
        }
        let declared = Set(textures.map(\.key))
        for pass in passes {
            guard let storage = pass.raw.field("storageTextures"), !storage.isUndefined else { continue }
            guard let entry = storage.objectFields?.first,
                  let name = entry.value.stringValue,
                  let texture = textures.first(where: { $0.key == name && $0.is3D }),
                  let program = programs[pass.program] else {
                throw GraphDiagnostic.unsupported("pass \(pass.id) storage output is not a declared 3D texture")
            }
            let declarations = try ShaderCompiler.bindingDeclarations(program.resolvedWGSL)
            let expectedFormat: String
            switch texture.format {
            case "rgba8": expectedFormat = "rgba8unorm"
            case "rgba16f": expectedFormat = "rgba16float"
            case "rgba32f": expectedFormat = "rgba32float"
            case "r8": expectedFormat = "r8unorm"
            case "r16f": expectedFormat = "r16float"
            case "r32f": expectedFormat = "r32float"
            default: expectedFormat = texture.format
            }
            guard declarations.contains(where: { declaration in
                declaration.name == entry.name &&
                    String(declaration.type.filter { !$0.isWhitespace }) ==
                    "texture_storage_3d<\(expectedFormat),write>"
            }) else {
                throw GraphDiagnostic.unsupported("pass \(pass.id) 3D storage format or access differs from texture \(name)")
            }
        }
        let producedTransient = Set(passes.flatMap { pass in
            pass.outputs.compactMap { $0.value.stringValue }.filter { !$0.hasPrefix("global_") }
        })
        guard declared.count == textures.count,
              Set(allocations.map(\.key)).count == allocations.count,
              producedTransient == Set(allocations.map(\.key)),
              producedTransient.isSubset(of: declared),
              allocations.allSatisfy({ $0.value.stringValue != nil }) else {
            throw GraphDiagnostic.unsupported("texture allocations differ from pass outputs")
        }
        var produced = Set<String>()
        var globalNames = Set<String>()
        var externalNames = Set<String>()
        var persistentNames = Set(textures.compactMap { texture -> String? in
            guard !texture.key.hasPrefix("global_"),
                  (texture.mipmaps || texture.raw.field("persistent")?.boolValue == true) else { return nil }
            return texture.key
        })
        for pass in passes {
            let storageNames = pass.raw.field("storageTextures")?.objectFields?
                .compactMap { $0.value.stringValue } ?? []
            let outputNames = Set(pass.outputs.compactMap { $0.value.stringValue } + storageNames)
            guard outputNames.count == pass.outputs.count + storageNames.count,
                  outputNames.allSatisfy({ declared.contains($0) ||
                      ($0.hasPrefix("global_") && !Self.isExternalMeshTexture($0)) }) else {
                throw GraphDiagnostic.unsupported("pass \(pass.id) targets undeclared or duplicate textures")
            }
            persistentNames.formUnion(storageNames)
            if programs[pass.program]?.stage != .compute,
               outputNames.contains(where: { name in
                   textures.contains(where: { $0.key == name && $0.is3D })
               }) {
                throw GraphDiagnostic.unsupported("pass \(pass.id) renders into a 3D texture")
            }
            for input in pass.inputs {
                guard let source = input.value.stringValue else {
                    throw GraphDiagnostic.unsupported("pass \(pass.id) has a non-string input")
                }
                if source != "none", !source.hasPrefix("global_"), !produced.contains(source) {
                    guard (declared.contains(source) || mediaNames.contains(source) ||
                           source == "midiNoteGrid"), !outputNames.contains(source) else {
                        throw GraphDiagnostic.unsupported("pass \(pass.id) reads feedback or an unproduced texture")
                    }
                    if producedTransient.contains(source) {
                        persistentNames.insert(source)
                    } else if mediaNames.contains(source) || input.key == "overlayTex" {
                        // The source pipeline allocates every declared graph
                        // texture even without a producer. Only host-owned
                        // media and CPU overlays are supplied externally.
                        externalNames.insert(source)
                    }
                } else if source != "none", !source.hasPrefix("global_"),
                          outputNames.contains(source) {
                    throw GraphDiagnostic.unsupported("pass \(pass.id) reads feedback or an unproduced texture")
                }
                if Self.isExternalMeshTexture(source) || source == "midiNoteGrid" {
                    externalNames.insert(source)
                } else if source.hasPrefix("global_") {
                    globalNames.insert(String(source.dropFirst(7)))
                }
            }
            let blends = pass.raw.field("blend").map { blend -> Bool in
                if case .bool(false) = blend { return false }
                return !blend.isUndefined
            } ?? false
            let partialViewport = pass.raw.field("viewport")?.isUndefined == false && {
                if case .bool(true) = pass.raw.field("clear") { return false }
                return true
            }()
            let maySkip = pass.conditions.map {
                !$0.runIf.isEmpty || !$0.skipIf.isEmpty
            } ?? false
            let loadsPreviousContents = programs[pass.program]?.stage != .compute &&
                pass.raw.field("clear")?.boolValue != true
            // The source keeps same-sized graph textures between frames. A
            // skipped writer leaves the previous frame intact, and a render
            // pass with loadOp=load may retain pixels discarded by its shader.
            // Only the authored persistent flag controls preservation on resize.
            if blends || partialViewport || maySkip || loadsPreviousContents {
                persistentNames.formUnion(outputNames.filter { !$0.hasPrefix("global_") })
            }
            for target in outputNames {
                if target.hasPrefix("global_") {
                    globalNames.insert(String(target.dropFirst(7)))
                } else {
                    produced.insert(target)
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
        self.globalSurfaceNames = globalNames.sorted()
        self.conservativePersistentTextureNames = persistentNames.sorted()
        self.persistentTextureNames = persistentNames.sorted()
        self.externalTextureNames = externalNames.sorted()
        self.mediaSteps = mediaSteps
    }

    /// A known full-screen writer makes its previous load contents
    /// unobservable. Keep all other ordinary textures in their source-matched
    /// cross-frame storage, including conditional, partial and resize-persistent
    /// ones. This is applied only after the renderer checks its actual fallback
    /// vertex program against the bundled full-screen triangle.
    func omittingProvenFullOverwrites(knownFullScreenVertex: Bool) -> RenderGraph {
        var result = self
        result.persistentTextureNames = conservativePersistentTextureNames
        guard knownFullScreenVertex else { return result }
        var produced = Set<String>()
        var readBeforeWrite = Set<String>()
        for pass in passes {
            for input in pass.inputs {
                if let name = input.value.stringValue, !produced.contains(name) {
                    readBeforeWrite.insert(name)
                }
            }
            produced.formUnion(pass.outputs.compactMap { $0.value.stringValue })
        }
        result.persistentTextureNames.removeAll { name in
            guard let texture = textures.first(where: { $0.key == name }),
                  !texture.mipmaps,
                  texture.raw.field("persistent")?.boolValue != true,
                  !readBeforeWrite.contains(name) else { return false }
            let writers = passes.filter { pass in
                pass.outputs.contains { $0.value.stringValue == name }
            }
            return !writers.isEmpty && writers.allSatisfy { pass in
                guard let program = programs[pass.program] else { return false }
                return ShaderCompiler.provesFullOverwrite(pass: pass, program: program)
            }
        }
        return result
    }

    private static func isExternalMeshTexture(_ name: String) -> Bool {
        name.range(of: #"^global_mesh\d+_(positions|normals|uvs)(?:_chain_\d+)?$"#,
            options: .regularExpression) != nil
    }

    func validateDimensions(for size: RenderSize, maximumTextureDimension2D: Int = 16_384) throws {
        var resolved: [String: RenderSize] = [:]
        for texture in textures {
            let dimensions = try RenderSize(
                width: texture.width.resolve(screen: size.width, parameters: dimensionParameters),
                height: texture.height.resolve(screen: size.height, parameters: dimensionParameters))
            let maximum = texture.is3D ? 2_048 : maximumTextureDimension2D
            guard dimensions.width <= maximum, dimensions.height <= maximum,
                  (try texture.depth?.resolve(screen: size.width, parameters: dimensionParameters) ?? 1) <= maximum else {
                throw GraphDiagnostic.unsupported("texture \(texture.key) exceeds the selected device capability profile")
            }
            resolved[texture.key] = dimensions
        }
        for pass in passes where programs[pass.program]?.stage == .compute {
            if pass.raw.field("storageTextures")?.isUndefined == false { continue }
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
                // Pipeline.collectDefaultUniforms merges pass uniforms in graph order.
                // Later pass values also govern shared scoped texture dimensions.
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
