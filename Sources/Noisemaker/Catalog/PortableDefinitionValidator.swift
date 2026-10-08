import Foundation

/// Mirrors the declaration checks in CanvasRenderer.registerPortableEffect.
/// Effect-schema validation is a separate source API and is not called by
/// Portable registration.
enum PortableDefinitionValidator {
    static func validateMetadata(_ definition: GraphValue) -> String? {
        guard definition.objectFields != nil else { return "expected a definition object" }
        if let starter = definition.field("starter"), bool(starter) == nil {
            return "starter must be boolean"
        }
        guard let passes = definition.field("passes")?.arrayValue, !passes.isEmpty else {
            return "passes must be a nonempty array"
        }
        for pass in passes {
            guard pass.objectFields != nil, let program = pass.field("program")?.stringValue,
                  !program.isEmpty else {
                return "each pass must name a program"
            }
            for key in ["inputs", "outputs"] {
                guard let value = pass.field(key) else { continue }
                guard let entries = value.objectFields,
                      entries.allSatisfy({ nonempty($0.value) }) else {
                    return "pass \(key) must map names to nonempty texture references"
                }
            }
        }
        if let globals = definition.field("globals") {
            guard let entries = globals.objectFields,
                  entries.allSatisfy({ $0.value.objectFields != nil }) else {
                return "globals must contain parameter objects"
            }
            for entry in entries {
                let spec = entry.value
                guard let choices = spec.field("choices") else { continue }
                guard let values = choices.objectFields else {
                    return "choices for \(entry.name) must be an object"
                }
                let stringType = spec.field("type")?.stringValue == "string"
                for choice in values {
                    if case .null = choice.value { continue }
                    if stringType {
                        if choice.value.stringValue == nil {
                            return "choices for \(entry.name) must map names to strings or null"
                        }
                    } else if !finiteNumber(choice.value) {
                        return "choices for \(entry.name) must map names to numbers or null"
                    }
                }
            }
        }
        if let aliases = definition.field("paramAliases") {
            guard let entries = aliases.objectFields else {
                return "paramAliases must map names to declared globals"
            }
            let globals = Set((definition.field("globals")?.objectFields ?? []).map(\.name))
            for entry in entries {
                guard let target = entry.value.stringValue, globals.contains(target) else {
                    return "paramAliases must map names to declared globals"
                }
            }
        }
        return nil
    }

    static func validateShaders(passes: [GraphValue], shaders: GraphValue) -> String? {
        guard shaders.objectFields != nil else { return "loaded shaders are required" }
        var hasGLSL = false
        var hasWGSL = false
        for pass in passes {
            guard let program = pass.field("program")?.stringValue,
                  let shader = shaders.field(program), shader.objectFields != nil else {
                return "missing shader source for Portable pass"
            }
            let glsl = nonempty(shader.field("glsl"))
            let wgsl = nonempty(shader.field("wgsl"))
            if !glsl && !wgsl { return "missing shader source for \(program)" }
            hasGLSL = hasGLSL || glsl
            hasWGSL = hasWGSL || wgsl
        }
        for pass in passes {
            guard let program = pass.field("program")?.stringValue,
                  let shader = shaders.field(program) else { continue }
            if hasGLSL && !nonempty(shader.field("glsl")) {
                return "missing glsl shader source for \(program)"
            }
            if hasWGSL && !nonempty(shader.field("wgsl")) {
                return "missing wgsl shader source for \(program)"
            }
        }
        return nil
    }

    private static func bool(_ value: GraphValue) -> Bool? {
        guard case .bool(let result) = value else { return nil }
        return result
    }

    private static func finiteNumber(_ value: GraphValue) -> Bool {
        guard case .number(let result) = value else { return false }
        return result.isFinite
    }

    private static func nonempty(_ value: GraphValue?) -> Bool {
        guard let text = value?.stringValue else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
