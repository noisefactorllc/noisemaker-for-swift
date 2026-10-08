import Foundation

/// Applies the demo host's initial ProgramState/control writes after compileGraph.
/// The compiler's six stage values remain untouched; this is a separate runtime
/// preparation step, just as it is in the locked JavaScript renderer.
public extension RenderGraph {
    func applyingInitialProgramState(registry: EffectRegistry) throws -> RenderGraph {
        let prepared = try InitialProgramState.apply(to: raw, source: source, registry: registry)
        let input = try NoisemakerCompiler(registry: registry).makeRenderGraphInput(prepared)
        return try RenderGraph(exportedCaseData: input)
    }
}

public extension NoisemakerCompiler {
    /// Compiles the source for the demo host's initial ProgramState controls.
    /// `compileStages` continues to expose the exact, unmodified compiler stages.
    func compileForHost(source: String) throws -> RenderGraph {
        let stages = try compileStages(source: source)
        let prepared = try InitialProgramState.apply(to: stages.graph, source: source,
                                                     validated: stages.validated, registry: registry)
        return try RenderGraph(exportedCaseData: makeRenderGraphInput(prepared))
    }
}

private enum InitialProgramState {
    static func apply(to raw: GraphValue, source: String, validated: ParserValue? = nil,
                      registry: EffectRegistry) throws -> GraphValue {
        guard let original = raw.field("passes")?.arrayValue else {
            throw CompilerIncomplete(stage: "initial program state", detail: "graph has no passes")
        }
        let validated = try validated ?? NoisemakerValidator.validate(
            NoisemakerParser.parse(source), registry: registry)
        let planned = try GraphValue.decode(validated.taggedValue())
        let steps = try InitialProgramState.steps(planned, registry: registry)
        var uniforms = original.map { OrderedObject($0.field("uniforms")) }
        var changed = false

        for step in steps {
            let passIndices = original.indices.filter {
                original[$0].field("stepIndex")?.numberValue == Double(step.index) &&
                original[$0].field("effectKey")?.stringValue == step.effectKey
            }
            guard !passIndices.isEmpty else { continue }
            let controlled = Set((step.effect.definition.field("globals")?.objectFields ?? [])
                .compactMap { $0.value.field("colorModeUniform")?.stringValue })
            for index in passIndices {
                let pass = original[index]
                var palette: GraphValue?
                for parameter in step.values {
                    guard !parameter.name.hasPrefix("_"),
                          let spec = step.effect.definition.field("globals")?.field(parameter.name),
                          spec.field("type")?.stringValue != "surface",
                          !InitialProgramState.isAutomation(parameter.value) else { continue }
                    let uniformName = spec.field("uniform")?.stringValue ?? parameter.name
                    guard !controlled.contains(uniformName) else { continue }
                    let converted = try InitialProgramState.convert(parameter.value, spec: spec,
                                                                    registry: registry)
                    for alias in pass.field("uniformAliases")?.objectFields ?? [] where
                        alias.value.stringValue == parameter.name ||
                        alias.value.stringValue == uniformName {
                        if let previous = uniforms[index][alias.name],
                           !previous.sameOrderedValue(as: converted) {
                            uniforms[index][alias.name] = converted
                            changed = true
                        }
                    }
                    guard let previous = uniforms[index][uniformName] else { continue }
                    if uniformName == "volumeSize",
                       pass.field("inheritsVolumeSize")?.boolValue == true { continue }
                    if !previous.sameOrderedValue(as: converted) {
                        uniforms[index][uniformName] = converted
                        changed = true
                    }
                    if let scoped = pass.field("scopedParams")?.field(uniformName)?.stringValue {
                        for other in original.indices {
                            guard let current = uniforms[other][scoped] else { continue }
                            if !current.sameOrderedValue(as: converted) {
                                uniforms[other][scoped] = converted
                                changed = true
                            }
                            if uniformName == "volumeSize",
                               original[other].field("inheritsVolumeSize")?.boolValue == true,
                               let inherited = uniforms[other][uniformName],
                               !inherited.sameOrderedValue(as: converted) {
                                uniforms[other][uniformName] = converted
                                changed = true
                            }
                        }
                    }
                    if spec.field("type")?.stringValue == "palette" { palette = converted }
                }
                if let palette {
                    let previous = uniforms[index].value
                    try ParameterUpdater.expandPalette(palette, in: &uniforms[index],
                                                       registry: registry)
                    if !previous.sameOrderedValue(as: uniforms[index].value) { changed = true }
                }
            }
        }

        // ProgramState._applyToPipeline publishes each step's stateSize to a
        // node-scoped global after its per-pass writes. A downstream consumer's
        // own default can otherwise overwrite an emitter's shared particle size.
        for step in steps {
            guard let value = step.values.first(where: { $0.name == "stateSize" })?.value else { continue }
            let scoped = "stateSize_node_\(step.index)"
            for index in original.indices {
                if let previous = uniforms[index][scoped],
                   !previous.sameOrderedValue(as: value) {
                    uniforms[index][scoped] = value
                    changed = true
                }
            }
        }

        // The demo calls CanvasRenderer.applyStepParameterValues after
        // ProgramState._applyToPipeline. That second call walks passes in graph
        // order, so a downstream effect can broadcast its scoped default after
        // ProgramState's final emitter-specific stateSize setUniform. In
        // pointsEmit(128).life(), life's stateSize default is 256 and this last
        // broadcast controls the actual particle texture dimensions.
        for index in original.indices {
            let pass = original[index]
            guard let number = pass.field("stepIndex")?.numberValue,
                  let stepIndex = Int(exactly: number),
                  let effectKey = pass.field("effectKey")?.stringValue,
                  let step = steps.first(where: {
                      $0.index == stepIndex && $0.effectKey == effectKey
                  }) else { continue }
            let controlled = Set((step.effect.definition.field("globals")?.objectFields ?? [])
                .compactMap { $0.value.field("colorModeUniform")?.stringValue })
            var palette: GraphValue?
            for parameter in step.values {
                guard parameter.name != "_skip",
                      let spec = step.effect.definition.field("globals")?.field(parameter.name),
                      spec.field("type")?.stringValue != "surface",
                      !isAutomation(parameter.value) else { continue }
                let uniformName = spec.field("uniform")?.stringValue ?? parameter.name
                guard !controlled.contains(uniformName) else { continue }
                if uniforms[index][uniformName] != nil,
                   uniformName == "volumeSize",
                   pass.field("inheritsVolumeSize")?.boolValue == true { continue }
                let converted = try convert(parameter.value, spec: spec, registry: registry)
                for alias in pass.field("uniformAliases")?.objectFields ?? [] where
                    alias.value.stringValue == parameter.name ||
                    alias.value.stringValue == uniformName {
                    if let previous = uniforms[index][alias.name],
                       previous.sameOrderedValue(as: converted) { continue }
                    uniforms[index][alias.name] = converted
                    changed = true
                }
                guard let previous = uniforms[index][uniformName] else { continue }
                if !previous.sameOrderedValue(as: converted) {
                    uniforms[index][uniformName] = converted
                    changed = true
                }
                if let scoped = pass.field("scopedParams")?.field(uniformName)?.stringValue {
                    // CanvasRenderer writes the source pass, then
                    // Pipeline.broadcastChainScopedParam writes every pass
                    // carrying this scoped uniform.
                    if uniforms[index][scoped]?.sameOrderedValue(as: converted) != true {
                        uniforms[index][scoped] = converted
                        changed = true
                    }
                    for other in original.indices where other != index {
                        guard let current = uniforms[other][scoped] else { continue }
                        if !current.sameOrderedValue(as: converted) {
                            uniforms[other][scoped] = converted
                            changed = true
                        }
                        if uniformName == "volumeSize",
                           original[other].field("inheritsVolumeSize")?.boolValue == true,
                           let inherited = uniforms[other][uniformName],
                           !inherited.sameOrderedValue(as: converted) {
                            uniforms[other][uniformName] = converted
                            changed = true
                        }
                    }
                }
                if spec.field("type")?.stringValue == "palette" { palette = converted }
            }
            if let palette {
                let previous = uniforms[index].value
                try ParameterUpdater.expandPalette(palette, in: &uniforms[index],
                                                   registry: registry)
                if !previous.sameOrderedValue(as: uniforms[index].value) { changed = true }
            }
        }
        guard changed else { return raw }
        var passes = original
        for index in passes.indices {
            var pass = OrderedObject(passes[index])
            pass["uniforms"] = uniforms[index].value
            passes[index] = pass.value
        }
        var prepared = OrderedObject(raw)
        prepared["passes"] = .array(passes)
        return prepared.value
    }
    struct Step {
        let index: Int
        let effectKey: String
        let effect: CatalogEffect
        let values: [GraphField]
    }

    static func steps(_ validated: GraphValue, registry: EffectRegistry) throws -> [Step] {
        var result: [Step] = []
        for plan in validated.field("plans")?.arrayValue ?? [] {
            for node in plan.field("chain")?.arrayValue ?? [] {
                guard node.field("builtin")?.boolValue != true,
                      let key = node.field("op")?.stringValue,
                      let number = node.field("temp")?.numberValue,
                      let index = Int(exactly: number),
                      let effect = registry.effect(key: key) else { continue }
                let args = node.field("args")
                var values: [GraphField] = []
                for global in effect.definition.field("globals")?.objectFields ?? [] {
                    guard let initial = args?.field(global.name) ?? global.value.field("default"),
                          !initial.isUndefined else { continue }
                    let ui = global.value.field("ui")
                    let hidden = ui?.field("control")?.boolValue == false ||
                        ui?.field("hidden")?.boolValue == true
                    values.append(GraphField(name: global.name,
                        value: hidden ? initial : validate(initial, spec: global.value,
                                                           registry: registry)))
                }
                result.append(Step(index: index, effectKey: key, effect: effect,
                                   values: values))
            }
        }
        return result
    }

    static func isAutomation(_ value: GraphValue) -> Bool {
        if ParameterUpdater.truthy(value.field("_varRef")) { return true }
        let type = value.field("type")?.stringValue ?? value.field("_ast")?.field("type")?.stringValue
        return ["Oscillator", "Midi", "Audio"].contains(type ?? "")
    }

    private static func convert(_ value: GraphValue, spec: GraphValue,
                                registry: EffectRegistry) throws -> GraphValue {
        // ProgramState leaves hidden controls' Func objects intact, then
        // CanvasRenderer.convertParameterForUniform applies parseInt/parseFloat
        // to those objects. JavaScript produces NaN; the source WebGPU packer
        // writes that number rather than evaluating the function.
        if let converted = try? ParameterUpdater.convert(value, spec: spec,
                                                         registry: registry) { return converted }
        if ["int", "float"].contains(spec.field("type")?.stringValue ?? "") {
            if let number = value.numberValue { return .number(number) }
            return .number(.nan)
        }
        return try ParameterUpdater.convert(value, spec: spec, registry: registry)
    }

    private static func validate(_ value: GraphValue, spec: GraphValue,
                                 registry: EffectRegistry) -> GraphValue {
        if isAutomation(value) { return value }
        let type = spec.field("type")?.stringValue ?? ""
        let fallback = spec.field("default") ?? .number(0)
        switch type {
        case "float", "int":
            let number: Double?
            if let numeric = value.numberValue {
                number = type == "int" ? numeric.rounded(.towardZero) : numeric
            } else if let text = value.stringValue {
                let pattern = type == "int" ? #"^[+-]?[0-9]+"#
                    : #"^[+-]?(?:(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"#
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                number = trimmed.range(of: pattern, options: .regularExpression)
                    .flatMap { Double(trimmed[$0]) }
            } else {
                number = nil
            }
            var result = number ?? fallback.numberValue ?? 0
            if let minimum = spec.field("min")?.numberValue { result = max(minimum, result) }
            if let maximum = spec.field("max")?.numberValue { result = min(maximum, result) }
            return .number(result)
        case "boolean": return .bool(ParameterUpdater.truthy(value))
        case "vec2", "vec3", "vec4", "color":
            if type == "color", let hex = value.stringValue, hex.hasPrefix("#"), hex.count >= 7,
               let converted = try? ParameterUpdater.convert(value, spec: spec,
                    registry: registry) { return converted }
            guard let array = value.arrayValue else { return fallback }
            let width = type == "vec2" ? 2 : (type == "vec4" ? 4 : 3)
            return .array(array.prefix(width).map { component in
                let numeric = component.numberValue ?? component.stringValue.flatMap { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let prefix = trimmed.range(of:
                        #"^[+-]?(?:(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"#,
                        options: .regularExpression) else { return nil }
                    return Double(trimmed[prefix])
                }
                return .number(numeric ?? 0)
            })
        default: return value
        }
    }
}
