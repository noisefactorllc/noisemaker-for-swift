import Foundation

struct OrderedObject {
    private(set) var fields: [GraphField]

    init(_ fields: [GraphField] = []) { self.fields = fields }
    init(_ value: GraphValue?) { fields = value?.objectFields ?? [] }

    subscript(_ key: String) -> GraphValue? {
        get { fields.first { $0.name == key }?.value }
        set {
            if let index = fields.firstIndex(where: { $0.name == key }) {
                if let newValue { fields[index] = GraphField(name: key, value: newValue) }
                else { fields.remove(at: index) }
            } else if let newValue {
                fields.append(GraphField(name: key, value: newValue))
            }
        }
    }

    var value: GraphValue { .object(fields) }
    var isEmpty: Bool { fields.isEmpty }
}

extension GraphValue {
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Preserve the source exporter's ordered tagged representation in stage
    /// differential tests and in-memory graph assembly.
    func taggedValue() -> Any {
        switch self {
        case .undefined: return ["$type": "undefined"]
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if value.isNaN { return ["$type": "number", "value": "NaN"] }
            if value == .infinity { return ["$type": "number", "value": "Infinity"] }
            if value == -.infinity { return ["$type": "number", "value": "-Infinity"] }
            if value == 0 && value.sign == .minus { return ["$type": "number", "value": "-0"] }
            return value
        case .string(let value): return value
        case .array(let values): return values.map { $0.taggedValue() }
        case .object(let fields):
            return ["$type": "object", "entries": fields.map { [$0.name, $0.value.taggedValue()] as [Any] }]
        case .map(let entries):
            return ["$type": "map", "entries": entries.map { [$0.key.taggedValue(), $0.value.taggedValue()] as [Any] }]
        case .tagged(let tag, let fields):
            var value: [String: Any] = ["$type": tag]
            for field in fields { value[field.name] = field.value.taggedValue() }
            return value
        }
    }

    func sameOrderedValue(as other: GraphValue) -> Bool {
        switch (self, other) {
        case (.undefined, .undefined), (.null, .null): return true
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
        case (.number(let lhs), .number(let rhs)):
            return lhs.bitPattern == rhs.bitPattern || (lhs.isNaN && rhs.isNaN)
        case (.string(let lhs), .string(let rhs)): return lhs == rhs
        case (.array(let lhs), .array(let rhs)):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
                pair.0.sameOrderedValue(as: pair.1)
            }
        case (.object(let lhs), .object(let rhs)):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
                pair.0.name == pair.1.name && pair.0.value.sameOrderedValue(as: pair.1.value)
            }
        case (.map(let lhs), .map(let rhs)):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
                pair.0.key.sameOrderedValue(as: pair.1.key) &&
                    pair.0.value.sameOrderedValue(as: pair.1.value)
            }
        case (.tagged(let lhsTag, let lhs), .tagged(let rhsTag, let rhs)):
            return lhsTag == rhsTag && lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
                pair.0.name == pair.1.name && pair.0.value.sameOrderedValue(as: pair.1.value)
            }
        default: return false
        }
    }
}
