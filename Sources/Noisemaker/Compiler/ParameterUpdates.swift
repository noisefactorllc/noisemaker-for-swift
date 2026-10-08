import Foundation

/// Immutable counterpart of the source renderer's per-step parameter path.
/// A new graph is validated before it is returned; the receiver is never
/// modified, including when a value requires recompilation or is invalid.
public extension RenderGraph {
    /// Applies one source UI step's values. Palette expansion runs after all
    /// explicit writes, as in applyStepParameterValues.
    func updatedParameters(stepIndex: Int, values: [GraphField],
                           registry: EffectRegistry) throws -> RenderGraph {
        guard let effectKey = passes.first(where: {
            $0.raw.field("stepIndex")?.numberValue == Double(stepIndex)
        })?.raw.field("effectKey")?.stringValue,
              let effect = registry.effect(key: effectKey) else {
            throw CompilerIncomplete(stage: "parameter update", detail: "step has no registered effect")
        }
        var ordinary: [GraphField] = []
        var palettes: [GraphField] = []
        for field in values {
            let parameter = ParameterUpdater.resolveAlias(field.name, effectKey: effectKey,
                                                          registry: registry)
            if effect.definition.field("globals")?.field(parameter)?.field("type")?.stringValue == "palette" {
                palettes.append(field)
            } else {
                ordinary.append(field)
            }
        }
        var result = self
        for field in ordinary + palettes {
            result = try result.updatedParameter(stepIndex: stepIndex, name: field.name,
                                                 value: field.value, registry: registry)
        }
        return result
    }

    func updatedParameter(stepIndex: Int, name: String, value: GraphValue,
                          registry: EffectRegistry) throws -> RenderGraph {
        guard stepIndex >= 0, !name.isEmpty,
              let originalPasses = raw.field("passes")?.arrayValue else {
            throw CompilerIncomplete(stage: "parameter update", detail: "invalid step or graph")
        }
        let matches = originalPasses.indices.filter {
            originalPasses[$0].field("stepIndex")?.numberValue == Double(stepIndex)
        }
        guard !matches.isEmpty,
              let effectKey = originalPasses[matches[0]].field("effectKey")?.stringValue,
              let effect = registry.effect(key: effectKey),
              matches.allSatisfy({ originalPasses[$0].field("effectKey")?.stringValue == effectKey }) else {
            throw CompilerIncomplete(stage: "parameter update", detail: "step has no single registered effect")
        }
        let parameterName = ParameterUpdater.resolveAlias(name, effectKey: effectKey, registry: registry)
        guard let spec = effect.definition.field("globals")?.field(parameterName) else {
            throw CompilerIncomplete(stage: "parameter update", detail: "unknown parameter \(name)")
        }
        if ParameterUpdater.truthy(spec.field("define")) {
            throw CompilerIncomplete(stage: "parameter update",
                                     detail: "\(parameterName) is a compile-time define; recompile the DSL")
        }
        if spec.field("type")?.stringValue == "surface" {
            throw CompilerIncomplete(stage: "parameter update",
                                     detail: "\(parameterName) changes graph inputs; recompile the DSL")
        }
        if parameterName.hasPrefix("_") || ParameterUpdater.isAutomationControlled(value) {
            return self
        }
        let uniformName = spec.field("uniform")?.stringValue ?? parameterName
        let controlled = Set((effect.definition.field("globals")?.objectFields ?? [])
            .compactMap { $0.value.field("colorModeUniform")?.stringValue })
        if controlled.contains(uniformName) { return self }
        let converted = try ParameterUpdater.convert(value, spec: spec, registry: registry)

        var passValues = originalPasses
        var broadcasts: [(uniform: String, scoped: String, value: GraphValue)] = []
        var wrote = false
        for index in matches {
            let pass = passValues[index]
            var uniforms = OrderedObject(pass.field("uniforms"))
            let aliases = pass.field("uniformAliases")?.objectFields ?? []
            let ownsUniform = uniforms[uniformName] != nil
            let inheritedVolume = uniformName == "volumeSize"
                && pass.field("inheritsVolumeSize")?.boolValue == true
            for alias in aliases where alias.value.stringValue == parameterName
                || alias.value.stringValue == uniformName {
                if uniforms[alias.name] != nil {
                    uniforms[alias.name] = converted
                    wrote = true
                }
            }
            if ownsUniform && !inheritedVolume {
                uniforms[uniformName] = converted
                wrote = true
                if let scoped = pass.field("scopedParams")?.field(uniformName)?.stringValue {
                    uniforms[scoped] = converted
                    broadcasts.append((uniformName, scoped, converted))
                }
            }
            if ownsUniform && spec.field("type")?.stringValue == "palette" {
                try ParameterUpdater.expandPalette(converted, in: &uniforms, registry: registry)
            }
            var updated = OrderedObject(pass)
            updated["uniforms"] = uniforms.value
            passValues[index] = updated.value
        }
        // The source per-step path ignores a known parameter when this step has
        // no writable uniform (notably inherited volumeSize on consumers).
        if !wrote { return self }
        for broadcast in broadcasts {
            for index in passValues.indices {
                var pass = OrderedObject(passValues[index])
                var uniforms = OrderedObject(pass["uniforms"])
                guard uniforms[broadcast.scoped] != nil else { continue }
                uniforms[broadcast.scoped] = broadcast.value
                if broadcast.uniform == "volumeSize",
                   pass["inheritsVolumeSize"]?.boolValue == true,
                   uniforms["volumeSize"] != nil {
                    uniforms["volumeSize"] = broadcast.value
                }
                pass["uniforms"] = uniforms.value
                passValues[index] = pass.value
            }
        }
        var updatedGraph = OrderedObject(raw)
        updatedGraph["passes"] = .array(passValues)
        let input = try NoisemakerCompiler(registry: registry).makeRenderGraphInput(updatedGraph.value)
        return try RenderGraph(exportedCaseData: input)
    }
}

enum ParameterUpdater {
    static func truthy(_ value: GraphValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .undefined, .null: return false
        case .bool(let bool): return bool
        case .number(let number): return number != 0 && !number.isNaN
        case .string(let string): return !string.isEmpty
        default: return true
        }
    }

    static func isAutomationControlled(_ value: GraphValue) -> Bool {
        if truthy(value.field("_varRef")) { return true }
        let type = value.field("type")?.stringValue ?? value.field("_ast")?.field("type")?.stringValue
        return ["Oscillator", "Midi", "Audio"].contains(type ?? "")
    }

    static func resolveAlias(_ name: String, effectKey: String, registry: EffectRegistry) -> String {
        let aliases = registry.paramAliases.mapEntries?.first {
            $0.key.stringValue == effectKey
        }?.value
        return aliases?.field(name)?.stringValue ?? name
    }

    static func convert(_ value: GraphValue, spec: GraphValue,
                        registry: EffectRegistry) throws -> GraphValue {
        let type = spec.field("type")?.stringValue ?? ""
        if let text = value.stringValue,
           (type == "member" || spec.field("enum")?.stringValue != nil
            || spec.field("enumPath")?.stringValue != nil),
           let resolved = resolveEnum(text, spec: spec, registry: registry) {
            return resolved
        }
        switch type {
        case "boolean", "button":
            return .bool(truthy(value))
        case "int":
            let number: Double
            if let bool = value.boolValue { number = bool ? 1 : 0 }
            else if let raw = value.numberValue { number = raw }
            else if let text = value.stringValue, let raw = sourceParseInt10(text) { number = raw }
            else { throw CompilerIncomplete(stage: "parameter update", detail: "integer value is not numeric") }
            guard number.isFinite, abs(number) < Double(Int.max) else {
                throw CompilerIncomplete(stage: "parameter update", detail: "integer value is out of range")
            }
            // JavaScript Math.round preserves negative zero for [-0.5, 0].
            if (number < 0 && number >= -0.5) || (number == 0 && number.sign == .minus) {
                return .number(-0.0)
            }
            return .number(floor(number + 0.5))
        case "float":
            let number = value.numberValue ?? value.stringValue.flatMap(sourceParseFloat)
            guard let number, number.isFinite else {
                throw CompilerIncomplete(stage: "parameter update", detail: "float value is not finite")
            }
            return .number(number)
        case "palette":
            // CanvasRenderer.convertParameterForUniform has no palette branch:
            // the original value is written before expandPalette applies JS
            // numeric coercion to its 1-based table lookup.
            return value
        case "color":
            if let components = value.arrayValue {
                var numbers = try components.prefix(3).map(numericComponent)
                while numbers.count < 3 { numbers.append(.number(0)) }
                return .array(numbers)
            }
            if let hex = value.stringValue, hex.hasPrefix("#"), hex.count >= 7 {
                let digits = Array(hex.dropFirst().prefix(6))
                var numbers: [GraphValue] = []
                for offset in stride(from: 0, to: 6, by: 2) {
                    guard let byte = UInt8(String(digits[offset...offset + 1]), radix: 16) else {
                        throw CompilerIncomplete(stage: "parameter update", detail: "invalid hex color")
                    }
                    numbers.append(.number(Double(byte) / 255))
                }
                return .array(numbers)
            }
            throw CompilerIncomplete(stage: "parameter update", detail: "color needs RGB array or hex")
        case "vec3", "vec4":
            guard let components = value.arrayValue else {
                throw CompilerIncomplete(stage: "parameter update", detail: "\(type) needs an array")
            }
            return .array(try components.map(numericComponent))
        default:
            return value
        }
    }

    private static func sourceParseInt10(_ text: String) -> Double? {
        let bytes = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var index = 0
        var negative = false
        if bytes.first == 45 || bytes.first == 43 {
            negative = bytes[0] == 45
            index = 1
        }
        let start = index
        while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 { index += 1 }
        guard index > start, let magnitude = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
            return nil
        }
        return negative ? -magnitude : magnitude
    }

    private static func sourceParseFloat(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = trimmed.range(of:
            #"^[+-]?(?:(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"#,
            options: .regularExpression) else { return nil }
        return Double(trimmed[prefix])
    }

    private static func numericComponent(_ value: GraphValue) throws -> GraphValue {
        let number = value.numberValue ?? value.stringValue.flatMap(sourceParseFloat)
        guard let number, number.isFinite else {
            throw CompilerIncomplete(stage: "parameter update", detail: "nonfinite vector component")
        }
        return .number(number)
    }

    private static func resolveEnum(_ name: String, spec: GraphValue,
                                    registry: EffectRegistry) -> GraphValue? {
        let prefixes = ["", spec.field("enum")?.stringValue, spec.field("enumPath")?.stringValue]
        for prefix in prefixes {
            guard let prefix else { continue }
            let path = (prefix.isEmpty ? name : "\(prefix).\(name)").split(separator: ".")
            var node: ParserValue? = registry.mergedEnums
            for component in path { node = node?.field(String(component)) }
            if node?.type == "Number" || node?.type == "Boolean" { node = node?.field("value") }
            if let node, !node.isUndefined,
               let converted = try? GraphValue.decode(node.taggedValue()) { return converted }
        }
        return nil
    }

    static func expandPalette(_ value: GraphValue, in uniforms: inout OrderedObject,
                              registry: EffectRegistry) throws {
        let index = paletteIndex(value)
        // The locked source returns null for these values, leaving the
        // dependent uniforms unchanged after writing the palette itself.
        if index <= 0 || index > Double(registry.paletteTable.count) { return }
        guard let integer = Int(exactly: index),
              (1...registry.paletteTable.count).contains(integer) else {
            throw CompilerIncomplete(stage: "parameter update", detail: "palette index has no source entry")
        }
        let palette = registry.paletteTable[integer - 1]
        for (uniform, field) in [("paletteOffset", "offset"), ("paletteAmp", "amp"),
                                 ("paletteFreq", "freq"), ("palettePhase", "phase"),
                                 ("paletteMode", "mode")] {
            if uniforms[uniform] != nil, let expanded = palette.field(field) {
                uniforms[uniform] = expanded
            }
        }
    }

    private static func paletteIndex(_ value: GraphValue) -> Double {
        switch value {
        case .number(let number): return number
        case .bool(let bool): return bool ? 1 : 0
        case .null: return 0
        case .string(let text): return paletteStringNumber(text)
        case .array(let elements):
            // JS relational comparison converts arrays through toString().
            if elements.isEmpty { return 0 }
            guard elements.count == 1 else { return .nan }
            switch elements[0] {
            case .null, .undefined: return 0
            case .number(let number): return number
            case .string(let text): return paletteStringNumber(text)
            case .array(let nested): return paletteIndex(.array(nested))
            default: return .nan
            }
        default: return .nan
        }
    }

    private static func paletteStringNumber(_ text: String) -> Double {
        // Number(string) trims ECMAScript WhiteSpace and LineTerminator code
        // points. Foundation's whitespace set also includes U+0085 (NEL),
        // which JavaScript leaves in place and rejects as a numeric string.
        let jsWhitespace = CharacterSet(charactersIn:
            "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}" +
            "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}" +
            "\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}" +
            "\u{205F}\u{3000}\u{FEFF}")
        let trimmed = text.trimmingCharacters(in: jsWhitespace)
        if trimmed.isEmpty { return 0 }
        if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
        if trimmed == "-Infinity" { return -.infinity }
        for (prefix, radix, digits) in [
            ("0x", 16, #"^[0-9a-fA-F]+$"#), ("0X", 16, #"^[0-9a-fA-F]+$"#),
            ("0b", 2, #"^[01]+$"#), ("0B", 2, #"^[01]+$"#),
            ("0o", 8, #"^[0-7]+$"#), ("0O", 8, #"^[0-7]+$"#)
        ] where trimmed.hasPrefix(prefix) {
            let body = String(trimmed.dropFirst(prefix.count))
            guard !body.isEmpty, body.range(of: digits, options: .regularExpression) != nil else {
                return .nan
            }
            return UInt64(body, radix: radix).map { Double($0) } ?? .infinity
        }
        guard trimmed.range(of:
            #"^[+-]?(?:(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)$"#,
            options: .regularExpression) != nil else { return .nan }
        return Double(trimmed) ?? .nan
    }
}
