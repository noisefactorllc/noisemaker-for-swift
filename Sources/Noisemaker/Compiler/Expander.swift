import Foundation

/// Converts the validated logical chain into source-ordered GPU passes.
public enum NoisemakerExpander {
    public static func expand(_ validated: ParserValue, registry: EffectRegistry) throws -> GraphValue {
        let compilation = try GraphValue.decode(validated.taggedValue())
        var expander = Expander(registry: registry)
        return try expander.expand(compilation)
    }

    private struct Expander {
        let registry: EffectRegistry
        var passes: [GraphValue] = []
        var programs = OrderedObject()
        var textureSpecs = OrderedObject()
        var textureMap: [String: String] = [:]
        var mediaSteps: [GraphValue] = []
        var mediaStepIds: Set<String> = []
        var lastWrittenSurface: String? = nil

        mutating func expand(_ compilation: GraphValue) throws -> GraphValue {
            guard let plans = compilation.field("plans")?.arrayValue else {
                throw CompilerIncomplete(stage: "expander", detail: "missing validated plans")
            }
            for (planIndex, plan) in plans.enumerated() {
                try expandPlan(plan, index: planIndex)
            }
            let surface = compilation.field("render")?.stringValue ?? lastWrittenSurface
            guard let surface else {
                throw CompilerIncomplete(stage: "expander", detail: "missing render surface")
            }
            return .object([
                GraphField(name: "passes", value: .array(passes)),
                GraphField(name: "errors", value: .array([])),
                GraphField(name: "programs", value: programs.value),
                GraphField(name: "textureSpecs", value: textureSpecs.value),
                GraphField(name: "renderSurface", value: .string(surface)),
                GraphField(name: "mediaSteps", value: .array(mediaSteps))
            ])
        }

        private mutating func expandPlan(_ plan: GraphValue, index: Int) throws {
            guard let steps = plan.field("chain")?.arrayValue else {
                throw CompilerIncomplete(stage: "expander", detail: "branch plan expansion")
            }
            let write = plan.field("write")
            let writeName = write?.field("name")?.stringValue
            let writeKind = write?.field("kind")?.stringValue
            var currentInput: String? = nil
            var currentInput3d: String? = nil
            var currentInputGeo: String? = nil
            var currentInputXyz: String? = nil
            var currentInputVel: String? = nil
            var currentInputRgba: String? = nil
            var particleID: String? = nil
            var lastInlineWrite: String? = nil
            var pipelineUniforms = OrderedObject()
            for (stepIndex, step) in steps.enumerated() {
                guard let op = step.field("op")?.stringValue,
                      let number = step.field("temp")?.numberValue,
                      let temp = Int(exactly: number), temp >= 0,
                      let arguments = step.field("args")?.objectFields else {
                    throw CompilerIncomplete(stage: "expander", detail: "malformed logical step")
                }
                let nodeID = "node_\(temp)"
                if step.field("builtin")?.boolValue == true {
                    switch op {
                    case "_read":
                        guard currentInput == nil, let name = step.field("args")?.field("tex")?.field("name")?.stringValue else {
                            throw CompilerIncomplete(stage: "expander", detail: "invalid read surface")
                        }
                        currentInput = "global_\(name)"
                        textureMap["\(nodeID)_out"] = currentInput
                    case "_write":
                        guard let name = step.field("args")?.field("tex")?.field("name")?.stringValue,
                              let source = currentInput else {
                            throw CompilerIncomplete(stage: "expander", detail: "invalid write surface")
                        }
                        if name != "none" {
                            let target = "global_\(name)"
                            if source != target {
                                passes.append(blitPass(id: "\(nodeID)_write_blit", source: source,
                                                       target: target, nodeID: nodeID, stepIndex: temp))
                                programs["blit"] = registry.blitProgram
                                lastWrittenSurface = name
                                lastInlineWrite = name
                            }
                        }
                        textureMap["\(nodeID)_out"] = source
                    case "_subchain_begin", "_subchain_end":
                        if let currentInput { textureMap["\(nodeID)_out"] = currentInput }
                        if let currentInput3d { textureMap["\(nodeID)_out3d"] = currentInput3d }
                        if let currentInputGeo { textureMap["\(nodeID)_outGeo"] = currentInputGeo }
                        if let currentInputXyz { textureMap["\(nodeID)_outXyz"] = currentInputXyz }
                        if let currentInputVel { textureMap["\(nodeID)_outVel"] = currentInputVel }
                        if let currentInputRgba { textureMap["\(nodeID)_outRgba"] = currentInputRgba }
                    default:
                        throw CompilerIncomplete(stage: "expander", detail: "builtin \(op)")
                    }
                    continue
                }
                lastInlineWrite = nil
                if step.field("args")?.field("_skip")?.boolValue == true {
                    textureMap["\(nodeID)_out"] = currentInput
                    continue
                }
                guard let effect = registry.effect(key: op) else {
                    throw CompilerIncomplete(stage: "expander", detail: "missing effect \(op)")
                }
                let definition = effect.definition
                let scope = "chain_\(index)"
                if let particle = definition.field("textures")?.field("global_xyz"), !particle.isUndefined {
                    particleID = nodeID
                    currentInputXyz = nil
                    currentInputVel = nil
                    currentInputRgba = nil
                }
                let defines = try compileDefines(definition: definition, arguments: arguments)
                let suffix = try defineSuffix(defines)
                try collectPrograms(definition: definition, nodeID: nodeID, suffix: suffix, defines: defines)
                let scopedParams = try collectTextures(definition: definition, nodeID: nodeID,
                                                       chainScope: scope, particleID: particleID)
                if let from = step.field("from")?.numberValue {
                    guard let index = Int(exactly: from), index >= 0 else {
                        throw CompilerIncomplete(stage: "expander", detail: "invalid input step index")
                    }
                    currentInput = textureMap["node_\(index)_out"]
                }
                let inheritsVolumeSize = currentInput3d != nil && pipelineUniforms["volumeSize"] != nil
                try updatePipelineUniforms(definition: definition, arguments: arguments,
                                           inheritsVolumeSize: inheritsVolumeSize,
                                           pipelineUniforms: &pipelineUniforms)
                guard let effectPasses = definition.field("passes")?.arrayValue else {
                    throw CompilerIncomplete(stage: "expander", detail: "effect \(op) has no passes")
                }
                for (passIndex, passDefinition) in effectPasses.enumerated() {
                    let pass = try expandPass(passDefinition, effect: effect, nodeID: nodeID,
                                              temp: temp, passIndex: passIndex,
                                              currentInput: currentInput,
                                              arguments: arguments,
                                              currentInput3d: currentInput3d,
                                              currentInputGeo: currentInputGeo,
                                              currentInputXyz: currentInputXyz,
                                              currentInputVel: currentInputVel,
                                              currentInputRgba: currentInputRgba,
                                              particleID: particleID,
                                              inheritsVolumeSize: inheritsVolumeSize,
                                              pipelineUniforms: &pipelineUniforms,
                                              chainScope: scope, defineSuffix: suffix,
                                              scopedParams: scopedParams,
                                              isLastStep: stepIndex == steps.count - 1,
                                              isLastPass: passIndex == effectPasses.count - 1,
                                              writeName: writeName, writeKind: writeKind,
                                              effectName: op)
                    passes.append(pass)
                }
                currentInput = textureMap["\(nodeID)_out"]
                if currentInput == nil, let outputName = definition.field("outputTex")?.stringValue {
                    if outputName == "inputTex", let from = step.field("from")?.numberValue {
                        guard let index = Int(exactly: from), index >= 0 else {
                            throw CompilerIncomplete(stage: "expander", detail: "invalid input step index")
                        }
                        currentInput = textureMap["node_\(index)_out"]
                    } else if outputName.hasPrefix("global_") {
                        currentInput = "\(outputName)_\(scope)"
                    } else {
                        currentInput = "\(nodeID)_\(outputName)"
                    }
                    textureMap["\(nodeID)_out"] = currentInput
                }
                if let output = definition.field("outputTex3d")?.stringValue {
                    if output != "inputTex3d" { currentInput3d = output.hasPrefix("global_")
                        ? "\(output)_\(scope)" : "\(nodeID)_\(output)" }
                    textureMap["\(nodeID)_out3d"] = currentInput3d
                }
                if let output = definition.field("outputGeo")?.stringValue {
                    if output != "inputGeo" { currentInputGeo = output.hasPrefix("global_")
                        ? "\(output)_\(scope)" : "\(nodeID)_\(output)" }
                    textureMap["\(nodeID)_outGeo"] = currentInputGeo
                }
                for (property, suffix) in [("outputXyz", "Xyz"), ("outputVel", "Vel"),
                                           ("outputRgba", "Rgba")] {
                    guard let output = definition.field(property)?.stringValue else { continue }
                    let existing: String?
                    switch suffix {
                    case "Xyz": existing = currentInputXyz
                    case "Vel": existing = currentInputVel
                    default: existing = currentInputRgba
                    }
                    let resolved = output == "input\(suffix)" ? existing
                        : scopeTexture(output, nodeID: nodeID, chainScope: scope, particleID: particleID)
                    textureMap["\(nodeID)_out\(suffix)"] = resolved
                    switch suffix {
                    case "Xyz": currentInputXyz = resolved
                    case "Vel": currentInputVel = resolved
                    default: currentInputRgba = resolved
                    }
                }
            }
            if let writeName, let source = currentInput {
                lastWrittenSurface = writeName
                if lastInlineWrite != writeName {
                    let target = "global_\(writeName)"
                    if source != target {
                        passes.append(blitPass(id: "final_blit_\(writeName)", source: source,
                                               target: target, nodeID: nil, stepIndex: nil))
                    }
                }
            }
        }

        private func blitPass(id: String, source: String, target: String,
                              nodeID: String?, stepIndex: Int?) -> GraphValue {
            var fields: [GraphField] = [
                GraphField(name: "id", value: .string(id)),
                GraphField(name: "program", value: .string("blit")),
                GraphField(name: "type", value: .string("render")),
                GraphField(name: "inputs", value: .object([GraphField(name: "src", value: .string(source))])),
                GraphField(name: "outputs", value: .object([GraphField(name: "color", value: .string(target))])),
                GraphField(name: "uniforms", value: .object([]))
            ]
            if let nodeID { fields.append(GraphField(name: "nodeId", value: .string(nodeID))) }
            if let stepIndex { fields.append(GraphField(name: "stepIndex", value: .number(Double(stepIndex)))) }
            return .object(fields)
        }

        private func compileDefines(definition: GraphValue, arguments: [GraphField]) throws -> OrderedObject {
            var defines = OrderedObject()
            let globals = definition.field("globals")?.objectFields ?? []
            for global in globals.sorted(by: { $0.name < $1.name }) {
                guard let define = global.value.field("define")?.stringValue else { continue }
                var value = arguments.first(where: { $0.name == global.name })?.value
                    ?? global.value.field("default") ?? .undefined
                if let inner = value.field("value") { value = inner }
                guard !value.isUndefined && !value.isNull else { continue }
                if global.value.field("type")?.stringValue == "member", let path = value.stringValue {
                    guard let resolved = resolveEnum(path) else {
                        throw CompilerIncomplete(stage: "expander", detail: "unresolved define enum \(path)")
                    }
                    value = resolved
                }
                defines[define] = value
            }
            return defines
        }

        private func defineSuffix(_ defines: OrderedObject) throws -> String {
            var suffix = ""
            for field in defines.fields {
                suffix += "__\(field.name)_\(try jsString(field.value))"
            }
            return suffix
        }

        private func jsString(_ value: GraphValue) throws -> String {
            if let string = value.stringValue { return string }
            if let boolean = value.boolValue { return boolean ? "true" : "false" }
            if let number = value.numberValue {
                if number.rounded() == number && abs(number) < 1e15 { return String(Int(number)) }
                return String(number)
            }
            throw CompilerIncomplete(stage: "expander", detail: "non-scalar compile-time define")
        }

        private mutating func collectPrograms(definition: GraphValue, nodeID: String,
                                              suffix: String, defines: OrderedObject) throws {
            for shader in definition.field("shaders")?.objectFields ?? [] {
                let key = "\(nodeID)_\(shader.name)\(suffix)"
                if programs[key] != nil { continue }
                guard let fields = shader.value.objectFields else {
                    throw CompilerIncomplete(stage: "expander", detail: "shader \(key) lacks fields")
                }
                var program = OrderedObject(fields)
                let layout = definition.field("uniformLayouts")?.field(shader.name)
                    ?? definition.field("uniformLayout") ?? .undefined
                program["uniformLayout"] = layout
                program["defines"] = defines.value
                programs[key] = program.value
            }
        }

        private mutating func collectTextures(definition: GraphValue, nodeID: String,
                                              chainScope: String, particleID: String?) throws -> OrderedObject {
            var scopedParams = OrderedObject()
            for texture in definition.field("textures")?.objectFields ?? [] {
                let key = scopeTexture(texture.name, nodeID: nodeID,
                                       chainScope: chainScope, particleID: particleID)
                guard texture.value.objectFields != nil else {
                    throw CompilerIncomplete(stage: "expander", detail: "texture \(key) has no spec")
                }
                var spec = OrderedObject(texture.value)
                for axis in ["width", "height"] {
                    if let dimension = spec[axis], let param = dimension.field("param")?.stringValue {
                        var scoped = OrderedObject(dimension)
                        let particleParam = param == "stateSize" && particleID != nil
                            && !texture.name.hasPrefix("global_")
                        let particleTexture = texture.name.hasPrefix("global_") && isParticleTexture(texture.name)
                        let suffix = (particleParam || particleTexture) ? particleID! : chainScope
                        let scopedName = param == "volumeSize" ? "volumeSize_\(chainScope)" : "\(param)_\(suffix)"
                        scoped["param"] = .string(scopedName)
                        spec[axis] = scoped.value
                        scopedParams[param] = .string(scopedName)
                    }
                    if let dimension = spec[axis], let param = dimension.field("screenDivide")?.stringValue {
                        var scoped = OrderedObject(dimension)
                        let suffix = isParticleTexture(texture.name) && particleID != nil
                            ? particleID! : chainScope
                        let scopedName = "\(param)_\(suffix)"
                        scoped["screenDivide"] = .string(scopedName)
                        spec[axis] = scoped.value
                        scopedParams[param] = .string(scopedName)
                    }
                }
                textureSpecs[key] = spec.value
            }
            // Source expander appends authored 3D specs after 2D textures and
            // marks each with is3D. Keep this order for graph-stage parity.
            for texture in definition.field("textures3d")?.objectFields ?? [] {
                let key = scopeTexture(texture.name, nodeID: nodeID,
                                       chainScope: chainScope, particleID: particleID)
                guard texture.value.objectFields != nil else {
                    throw CompilerIncomplete(stage: "expander", detail: "texture \(key) has no spec")
                }
                var spec = OrderedObject(texture.value)
                spec["is3D"] = .bool(true)
                textureSpecs[key] = spec.value
            }
            return scopedParams
        }

        private func isParticleTexture(_ name: String) -> Bool {
            ["global_xyz", "global_vel", "global_rgba", "global_points_trail",
             "global_life_data"].contains(name)
        }

        private func scopeTexture(_ name: String, nodeID: String,
                                  chainScope: String, particleID: String?) -> String {
            if name.hasPrefix("global_") {
                if isParticleTexture(name), let particleID { return "\(name)_\(particleID)" }
                return "\(name)_\(chainScope)"
            }
            return "\(nodeID)_\(name)"
        }

        private mutating func updatePipelineUniforms(definition: GraphValue, arguments: [GraphField],
                                                      inheritsVolumeSize: Bool,
                                                      pipelineUniforms: inout OrderedObject) throws {
            let globals = definition.field("globals")?.objectFields ?? []
            for global in globals {
                let spec = global.value
                if let uniform = spec.field("uniform")?.stringValue,
                   let fallback = spec.field("default"), !fallback.isUndefined,
                   pipelineUniforms[uniform] == nil {
                    pipelineUniforms[uniform] = try resolveDefault(fallback, spec: spec)
                }
                if spec.field("type")?.stringValue == "surface",
                   let mode = spec.field("colorModeUniform")?.stringValue,
                   !arguments.contains(where: { $0.name == global.name }) {
                    pipelineUniforms[mode] = .number(spec.field("default")?.stringValue == "none" ? 0 : 1)
                }
            }
            var controlled: Set<String> = []
            for argument in arguments {
                guard argument.value.field("kind")?.stringValue != nil,
                      let spec = globals.first(where: { $0.name == argument.name })?.value,
                      let mode = spec.field("colorModeUniform")?.stringValue else { continue }
                pipelineUniforms[mode] = .number(argument.value.field("name")?.stringValue == "none" ? 0 : 1)
                controlled.insert(mode)
            }
            for argument in arguments {
                if argument.value.field("kind")?.stringValue != nil { continue }
                let spec = globals.first(where: { $0.name == argument.name })?.value
                let uniform = spec?.field("uniform")?.stringValue ?? argument.name
                if controlled.contains(uniform) { continue }
                if uniform == "volumeSize" && inheritsVolumeSize { continue }
                let value = argument.value.field("value") ?? argument.value
                pipelineUniforms[uniform] = value
            }
        }

        private func resolveDefault(_ value: GraphValue, spec: GraphValue) throws -> GraphValue {
            if spec.field("type")?.stringValue == "member", let path = value.stringValue {
                return resolveEnum(path) ?? value
            }
            return value
        }

        private func resolveEnum(_ path: String) -> GraphValue? {
            var value: GraphValue? = registry.stdEnumsGraph
            for part in path.split(separator: ".") { value = value?.field(String(part)) }
            return value?.field("value")
        }

        private mutating func expandPass(_ passDefinition: GraphValue, effect: CatalogEffect,
                                         nodeID: String, temp: Int, passIndex: Int,
                                         currentInput: String?, arguments: [GraphField],
                                         currentInput3d: String?, currentInputGeo: String?,
                                         currentInputXyz: String?, currentInputVel: String?,
                                         currentInputRgba: String?, particleID: String?,
                                         inheritsVolumeSize: Bool,
                                         pipelineUniforms: inout OrderedObject,
                                         chainScope: String, defineSuffix: String,
                                         scopedParams: OrderedObject,
                                         isLastStep: Bool, isLastPass: Bool,
                                         writeName: String?, writeKind: String?,
                                         effectName: String) throws -> GraphValue {
            guard let baseProgram = passDefinition.field("program")?.stringValue else {
                throw CompilerIncomplete(stage: "expander", detail: "pass \(nodeID)_\(passIndex) lacks program")
            }
            var program = "\(nodeID)_\(baseProgram)\(defineSuffix)"
            if let passDefines = passDefinition.field("defines"), !passDefines.isUndefined {
                guard let fields = passDefines.objectFields else {
                    throw CompilerIncomplete(stage: "expander", detail: "malformed pass-specific defines")
                }
                var passSuffix = ""
                for field in fields.sorted(by: { $0.name < $1.name }) {
                    passSuffix += "__\(field.name)_\(try jsString(field.value))"
                }
                let variant = program + passSuffix
                if let base = programs[program], programs[variant] == nil {
                    var copy = OrderedObject(base)
                    var merged = OrderedObject(base.field("defines"))
                    for field in fields { merged[field.name] = field.value }
                    copy["defines"] = merged.value
                    programs[variant] = copy.value
                }
                program = variant
            }
            let controlKeys = ["entryPoint", "drawMode", "drawBuffers", "count", "countUniform",
                               "repeat", "blend", "conditions", "workgroups", "storageBuffers",
                               "storageTextures", "name", "type", "clear", "viewport", "samplerTypes"]
            var fields: [GraphField] = [
                GraphField(name: "id", value: .string("\(nodeID)_pass_\(passIndex)")),
                GraphField(name: "program", value: .string(program))
            ]
            for key in controlKeys {
                fields.append(GraphField(name: key, value: passDefinition.field(key) ?? .undefined))
            }
            var uniforms = pipelineUniforms
            let globals = effect.definition.field("globals")?.objectFields ?? []
            var specs = OrderedObject()
            var aliases = OrderedObject()
            let conditionalUniforms = Set((effect.definition.field("passes")?.arrayValue ?? [])
                .flatMap { pass in
                    ["runIf", "skipIf"].flatMap { key in
                        (pass.field("conditions")?.field(key)?.arrayValue ?? [])
                            .compactMap { $0.field("uniform")?.stringValue }
                    }
                })
            for global in globals {
                let spec = global.value
                let uniform = spec.field("uniform")?.stringValue ?? global.name
                let type = spec.field("type")?.stringValue
                if (type == "float" || type == "int") && spec.field("choices")?.isUndefined != false {
                    var range = OrderedObject()
                    range["min"] = spec.field("min")?.numberValue.map { .number($0) } ?? .number(0)
                    range["max"] = spec.field("max")?.numberValue.map { .number($0) } ?? .number(100)
                    specs[uniform] = range.value
                } else if type == "int", let choices = spec.field("choices"),
                          !choices.isUndefined, conditionalUniforms.contains(uniform) {
                    var selector = OrderedObject()
                    selector["type"] = .string("int")
                    if let minimum = spec.field("min")?.numberValue,
                       let maximum = spec.field("max")?.numberValue,
                       minimum.isFinite, maximum.isFinite {
                        selector["min"] = .number(minimum)
                        selector["max"] = .number(maximum)
                    }
                    specs[uniform] = selector.value
                }
            }
            for mapping in passDefinition.field("uniforms")?.objectFields ?? [] {
                if let constant = mapping.value.numberValue { uniforms[mapping.name] = .number(constant) }
                else if let name = mapping.value.stringValue {
                    if name != mapping.name { aliases[mapping.name] = .string(name) }
                    if let value = pipelineUniforms[mapping.name] ?? pipelineUniforms[name] {
                        uniforms[mapping.name] = value
                    } else if let defaultValue = globals.first(where: { $0.name == name })?.value.field("default") {
                        uniforms[mapping.name] = defaultValue
                    }
                } else {
                    throw CompilerIncomplete(stage: "expander", detail: "non-scalar pass uniform mapping")
                }
            }
            for global in globals where global.value.field("type")?.stringValue == "palette" {
                let uniformName = global.value.field("uniform")?.stringValue ?? global.name
                guard let index = uniforms[uniformName]?.numberValue, index.isFinite,
                      index.rounded() == index, index >= 1,
                      index <= Double(registry.paletteTable.count) else { continue }
                let palette = registry.paletteTable[Int(index) - 1]
                for (target, source) in [("paletteOffset", "offset"), ("paletteAmp", "amp"),
                                         ("paletteFreq", "freq"), ("palettePhase", "phase"),
                                         ("paletteMode", "mode")] {
                    if uniforms[target] != nil, let value = palette.field(source) {
                        uniforms[target] = value
                        pipelineUniforms[target] = value
                    }
                }
            }
            let inputs = try mapInputs(passDefinition.field("inputs"), currentInput: currentInput,
                                       currentInput3d: currentInput3d,
                                       currentInputGeo: currentInputGeo,
                                       currentInputXyz: currentInputXyz,
                                       currentInputVel: currentInputVel,
                                       currentInputRgba: currentInputRgba,
                                       particleID: particleID,
                                       arguments: arguments, effect: effect, nodeID: nodeID,
                                       chainScope: chainScope, writeName: writeName,
                                       writeKind: writeKind, stepIndex: temp,
                                       effectName: effectName)
            let outputs = try mapOutputs(passDefinition.field("outputs"), nodeID: nodeID,
                                         chainScope: chainScope, particleID: particleID,
                                         lastStep: isLastStep,
                                         lastPass: isLastPass, writeName: writeName)
            for scoped in scopedParams.fields {
                guard let destination = scoped.value.stringValue else { continue }
                if let value = uniforms[scoped.name] {
                    uniforms[destination] = value
                    pipelineUniforms[destination] = value
                }
            }
            fields += [GraphField(name: "inputs", value: inputs),
                       GraphField(name: "outputs", value: outputs),
                       GraphField(name: "uniforms", value: uniforms.value),
                       GraphField(name: "effectKey", value: .string("\(effect.namespace).\(effect.function)")),
                       GraphField(name: "effectFunc", value: .string(effect.function)),
                       GraphField(name: "effectNamespace", value: .string(effect.namespace)),
                       GraphField(name: "nodeId", value: .string(nodeID)),
                       GraphField(name: "stepIndex", value: .number(Double(temp)))]
            if inheritsVolumeSize {
                fields.append(GraphField(name: "inheritsVolumeSize", value: .bool(true)))
            }
            if effect.definition.field("globals")?.objectFields != nil {
                fields.append(GraphField(name: "uniformSpecs", value: specs.value))
            }
            if !aliases.isEmpty {
                fields.append(GraphField(name: "uniformAliases", value: aliases.value))
            }
            if !scopedParams.isEmpty {
                fields.append(GraphField(name: "scopedParams", value: scopedParams.value))
            }
            return .object(fields)
        }

        private mutating func mapInputs(_ inputSpec: GraphValue?, currentInput: String?,
                               currentInput3d: String?, currentInputGeo: String?,
                               currentInputXyz: String?, currentInputVel: String?,
                               currentInputRgba: String?, particleID: String?,
                               arguments: [GraphField], effect: CatalogEffect, nodeID: String,
                               chainScope: String, writeName: String?, writeKind: String?,
                               stepIndex: Int, effectName: String) throws -> GraphValue {
            var inputs = OrderedObject()
            for input in inputSpec?.objectFields ?? [] {
                guard let reference = input.value.stringValue else {
                    throw CompilerIncomplete(stage: "expander", detail: "non-string input reference")
                }
                let value: String
                if reference == "inputTex" || (reference.hasPrefix("o") && Int(reference.dropFirst()) != nil) {
                    value = currentInput ?? reference
                } else if reference == "inputTex3d" { value = currentInput3d ?? reference }
                else if reference == "inputGeo" { value = currentInputGeo ?? reference }
                else if reference == "inputXyz" { value = currentInputXyz ?? reference }
                else if reference == "inputVel" { value = currentInputVel ?? reference }
                else if reference == "inputRgba" { value = currentInputRgba ?? reference }
                else if reference == "noise" { value = "global_noise" }
                else if reference == "midiNoteGrid" { value = "midiNoteGrid" }
                else if reference == "feedback" || reference == "selfTex" {
                    if let writeName {
                        value = "\(writeKind == "feedback" ? "feedback" : "global")_\(writeName)"
                    } else {
                        value = currentInput ?? "global_inputTex"
                    }
                } else if effect.definition.field("externalTexture")?.stringValue == reference {
                    value = "\(reference)_step_\(stepIndex)"
                    if mediaStepIds.insert(value).inserted {
                        mediaSteps.append(.object([
                            GraphField(name: "textureId", value: .string(value)),
                            GraphField(name: "uniform", value: .string(input.name)),
                            GraphField(name: "stepIndex", value: .number(Double(stepIndex))),
                            GraphField(name: "effect", value: .string(effectName))
                        ]))
                    }
                } else if let argument = arguments.first(where: { $0.name == reference })?.value {
                    if argument.isNull || argument.isUndefined { continue }
                    if argument.field("kind")?.stringValue == "temp",
                       let index = argument.field("index")?.numberValue,
                       let integer = Int(exactly: index), integer >= 0,
                       let source = textureMap["node_\(integer)_out"] {
                        value = source
                    } else if let kind = argument.field("kind")?.stringValue,
                       let name = argument.field("name")?.stringValue {
                        if kind == "pipeline" && (name == "inputTex" || name == "inputColor") {
                            value = currentInput ?? name
                        } else if ["output", "source", "vol", "geo", "xyz", "vel", "rgba"].contains(kind) {
                            value = name == "none" ? "none" : "global_\(name)"
                        } else {
                            throw CompilerIncomplete(stage: "expander", detail: "texture argument kind \(kind)")
                        }
                    } else if let name = argument.stringValue { value = name }
                    else { throw CompilerIncomplete(stage: "expander", detail: "texture argument \(reference)") }
                } else if reference.hasPrefix("global_") {
                    value = scopeTexture(reference, nodeID: nodeID,
                                         chainScope: chainScope, particleID: particleID)
                }
                else if reference == "outputTex" { value = "\(nodeID)_out" }
                else { value = "\(nodeID)_\(reference)" }
                inputs[input.name] = .string(value)
            }
            return inputs.value
        }

        private mutating func mapOutputs(_ outputSpec: GraphValue?, nodeID: String,
                                         chainScope: String, particleID: String?, lastStep: Bool,
                                         lastPass: Bool, writeName: String?) throws -> GraphValue {
            var outputs = OrderedObject()
            for output in outputSpec?.objectFields ?? [] {
                guard let reference = output.value.stringValue else {
                    throw CompilerIncomplete(stage: "expander", detail: "non-string output reference")
                }
                let virtual: String
                if reference == "outputTex" {
                    if lastStep && lastPass, let writeName {
                        virtual = "global_\(writeName)"
                        lastWrittenSurface = writeName
                    } else { virtual = "\(nodeID)_out" }
                    textureMap["\(nodeID)_out"] = virtual
                    textureMap[virtual] = virtual
                } else if reference.hasPrefix("global_") {
                    virtual = scopeTexture(reference, nodeID: nodeID,
                                           chainScope: chainScope, particleID: particleID)
                }
                else { virtual = "\(nodeID)_\(reference)" }
                outputs[output.name] = .string(virtual)
            }
            return outputs.value
        }
    }
}
