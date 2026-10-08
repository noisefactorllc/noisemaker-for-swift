import Foundation

public struct CatalogEffect: Sendable {
    public let key: String
    public let namespace: String
    public let name: String
    public let function: String
    public let starter: Bool
    public let registrationKeys: [String]
    public let definition: GraphValue
}

public enum CatalogError: Error, CustomStringConvertible, Sendable {
    case malformed(String)
    case missingResource

    public var description: String {
        switch self {
        case .malformed(let detail): return "Malformed catalog: \(detail)"
        case .missingResource: return "Bundled catalog resource is missing"
        }
    }
}

/// Source-bound effect and validator tables exported from the locked upstream.
/// The definitions retain their ordered tagged JS fields and original WGSL.
public struct EffectRegistry: Sendable {
    public let authorityCommit: String
    public let sourceManifestSha256: String
    public private(set) var effects: [CatalogEffect]
    public private(set) var validatorOps: ParserValue
    public private(set) var mergedEnums: ParserValue
    public let stdEnums: ParserValue
    let stdEnumsGraph: GraphValue
    public private(set) var paramAliases: GraphValue
    public let effectAliases: GraphValue
    public let defaultVertex: GraphValue
    public let blitProgram: GraphValue
    public let paletteTable: [GraphValue]
    public private(set) var starterOps: [String]

    private var effectsByKey: [String: Int]
    private var effectsByRegistrationKey: [String: Int]
    private var starters: Set<String>

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schemaVersion"] as? Int == 1,
              let authority = root["authority"] as? [String: Any],
              let commit = authority["commit"] as? String,
              let manifest = authority["sourceManifestSha256"] as? String,
              let records = root["effects"] as? [[String: Any]],
              let count = root["effectCount"] as? Int,
              count == records.count,
              let rawOps = root["validatorOps"],
              let rawEnums = root["mergedEnums"],
              let rawStdEnums = root["stdEnums"],
              let rawParamAliases = root["paramAliases"],
              let rawEffectAliases = root["effectAliases"],
              let rawVertex = root["defaultVertex"],
              let rawBlit = root["blitProgram"],
              let rawPalette = root["paletteTable"] as? [Any], rawPalette.count == 55,
              let starterOps = root["starterOps"] as? [String] else {
            throw CatalogError.malformed("missing version, authority, effects, or compiler tables")
        }
        authorityCommit = commit
        sourceManifestSha256 = manifest
        validatorOps = try ParserValue.decodeTagged(rawOps)
        mergedEnums = try ParserValue.decodeTagged(rawEnums)
        stdEnums = try ParserValue.decodeTagged(rawStdEnums)
        stdEnumsGraph = try GraphValue.decode(rawStdEnums)
        paramAliases = try GraphValue.decode(rawParamAliases)
        effectAliases = try GraphValue.decode(rawEffectAliases)
        defaultVertex = try GraphValue.decode(rawVertex)
        blitProgram = try GraphValue.decode(rawBlit)
        paletteTable = try rawPalette.map(GraphValue.decode)
        self.starterOps = starterOps
        starters = Set(starterOps)

        var effects: [CatalogEffect] = []
        var byKey: [String: Int] = [:]
        var byRegistration: [String: Int] = [:]
        for (index, item) in records.enumerated() {
            guard let key = item["key"] as? String,
                  let namespace = item["namespace"] as? String,
                  let name = item["name"] as? String,
                  let function = item["func"] as? String,
                  let registrationKeys = item["registrationKeys"] as? [String],
                  let starter = item["starter"] as? Bool,
                  let definition = item["value"],
                  byKey[key] == nil else {
                throw CatalogError.malformed("invalid or duplicate effect at index \(index)")
            }
            let value = try GraphValue.decode(definition)
            effects.append(CatalogEffect(key: key, namespace: namespace, name: name,
                                         function: function, starter: starter,
                                         registrationKeys: registrationKeys, definition: value))
            byKey[key] = index
            for registrationKey in registrationKeys { byRegistration[registrationKey] = index }
        }
        self.effects = effects
        effectsByKey = byKey
        effectsByRegistrationKey = byRegistration
        guard validatorOps.fields?.count == effects.count,
              starters.count == starterOps.count else {
            throw CatalogError.malformed("validator op or starter inventory is inconsistent")
        }
    }

    private static let bundledBaseline: Result<EffectRegistry, CatalogError> = {
        #if SWIFT_PACKAGE
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json") else {
            return .failure(.missingResource)
        }
        do {
            return .success(try EffectRegistry(data: Data(contentsOf: url)))
        } catch {
            return .failure(.malformed("bundled resource: \(error)"))
        }
        #else
        return .failure(.missingResource)
        #endif
    }()

    public static func bundled() throws -> EffectRegistry {
        try bundledBaseline.get()
    }

    public func effect(key: String) -> CatalogEffect? {
        guard let index = effectsByKey[key] ?? effectsByRegistrationKey[key] else { return nil }
        return effects[index]
    }

    public func validatorOp(_ key: String) -> ParserValue? { validatorOps.field(key) }
    public func isStarter(_ key: String) -> Bool { starters.contains(key) }

    /// Registers sources supplied without an order. Use `orderedShaderSources`
    /// when importing sidecars whose order must match the source registry.
    public mutating func registerPortable(definitionJSON: Data,
                                           shaderSources: [String: String]) throws {
        let ordered = shaderSources.keys.sorted().compactMap { program -> (String, String)? in
            shaderSources[program].map { (program, $0) }
        }
        try registerPortable(definitionJSON: definitionJSON, orderedShaderSources: ordered)
    }

    /// Registers Portable WGSL sidecars in their source-defined order.
    public mutating func registerPortable(definitionJSON: Data,
                                           orderedShaderSources: [(String, String)]) throws {
        let source = try OrderedJSON.decode(definitionJSON)
        guard let fields = source.objectFields,
              let function = source.field("func")?.stringValue ?? source.field("name")?.stringValue,
              function.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: String.CompareOptions.regularExpression) != nil,
              source.field("namespace")?.stringValue == nil || source.field("namespace")?.stringValue == "user",
              let passes = source.field("passes")?.arrayValue, !passes.isEmpty else {
            throw CatalogError.malformed("invalid Portable identity or passes")
        }
        let reserved: Set<String> = ["constructor", "__proto__", "prototype", "toString", "toLocaleString",
                                     "valueOf", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable",
                                     "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__"]
        guard !reserved.contains(function), !containsReservedKey(source, reserved: reserved) else {
            throw CatalogError.malformed("reserved Portable metadata key")
        }
        let key = "user/\(function)"
        guard effectsByKey[key] == nil else { throw CatalogError.malformed("duplicate Portable \(function)") }
        var shaders = OrderedObject(source.field("shaders"))
        for (program, text) in orderedShaderSources {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CatalogError.malformed("empty shader source for \(program)")
            }
            var shader = OrderedObject(shaders[program])
            shader["wgsl"] = GraphValue.string(text)
            shaders[program] = shader.value
        }
        for pass in passes {
            guard let program = pass.field("program")?.stringValue, !program.isEmpty,
                  let wgsl = shaders[program]?.field("wgsl")?.stringValue, !wgsl.isEmpty else {
                throw CatalogError.malformed("Portable pass lacks WGSL program")
            }
        }
        var definition = OrderedObject()
        for field in fields where field.name != "shaders" { definition[field.name] = field.value }
        definition["func"] = .string(function)
        definition["namespace"] = .string("user")
        definition["shaders"] = shaders.value
        let consumedInputs = passes.contains { (pass: GraphValue) in
            let inputs: [GraphField] = pass.field("inputs")?.objectFields ?? []
            return inputs.contains { (input: GraphField) in
                ["inputTex", "inputTex3d", "inputGeo", "inputXyz", "inputVel", "inputRgba",
                 "src", "o0", "o1", "o2", "o3", "o4", "o5", "o6", "o7"].contains(input.value.stringValue ?? "")
            }
        }
        let starter = source.field("starter")?.boolValue ?? !consumedInputs
        let aliases = ["user.\(function)", key]
        let effect = CatalogEffect(key: key, namespace: "user", name: function,
                                   function: function, starter: starter,
                                   registrationKeys: aliases, definition: definition.value)
        let globals = source.field("globals")?.objectFields ?? []
        var updatedParamAliases: GraphValue?
        if let aliases = source.field("paramAliases")?.objectFields {
            for alias in aliases {
                guard let target = alias.value.stringValue,
                      globals.contains(where: { $0.name == target }) else {
                    throw CatalogError.malformed("Portable parameter alias has no declared target")
                }
            }
            var entries = paramAliases.mapEntries ?? []
            entries.append(GraphMapEntry(key: .string("user.\(function)"),
                                         value: .object(aliases)))
            updatedParamAliases = .map(entries)
        }
        let args: [ParserValue] = try globals.map { global in
            let spec = global.value
            var opArg: [(String, ParserValue)] = [("name", .string(global.name))]
            for fieldName in ["type", "default", "enum", "enumPath", "min", "max", "uniform", "choices"] {
                let raw = fieldName == "type" && spec.field("type")?.stringValue == "vec4"
                    ? GraphValue.string("color") : (spec.field(fieldName) ?? .undefined)
                opArg.append((fieldName, try ParserValue.decodeTagged(raw.taggedValue())))
            }
            return ParserValue.object(opArg)
        }
        let opSpec = ParserValue.object([("name", .string(function)), ("args", .array(args))])
        var ops = validatorOps.fields?.map { ($0.name, $0.value) } ?? []
        ops.append(("user.\(function)", opSpec))

        // Publish the completed registration only after every validation and
        // conversion above succeeds. A rejected definition must not leave a
        // partially visible effect or alias in this value-type registry.
        let index = effects.count
        effects.append(effect)
        effectsByKey[key] = index
        for alias in aliases { effectsByRegistrationKey[alias] = index }
        if let updatedParamAliases { paramAliases = updatedParamAliases }
        validatorOps = .object(ops)
        if starter {
            starterOps.append("user.\(function)")
            starters.insert("user.\(function)")
        }
    }

    private func containsReservedKey(_ value: GraphValue, reserved: Set<String>) -> Bool {
        if let fields = value.objectFields {
            return fields.contains { reserved.contains($0.name) || containsReservedKey($0.value, reserved: reserved) }
        }
        if let elements = value.arrayValue {
            return elements.contains { containsReservedKey($0, reserved: reserved) }
        }
        return false
    }
}
