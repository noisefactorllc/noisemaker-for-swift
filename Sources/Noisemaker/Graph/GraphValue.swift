import Foundation
import CoreFoundation

public struct GraphField: Sendable {
    public let name: String
    public let value: GraphValue
    public init(name: String, value: GraphValue) {
        self.name = name
        self.value = value
    }
}

public struct GraphMapEntry: Sendable {
    public let key: GraphValue
    public let value: GraphValue
    public init(key: GraphValue, value: GraphValue) {
        self.key = key
        self.value = value
    }
}

public indirect enum GraphValue: Sendable {
    case undefined
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([GraphValue])
    case object([GraphField])
    case map([GraphMapEntry])
    case tagged(String, [GraphField])

    public var isUndefined: Bool {
        if case .undefined = self { return true }
        return false
    }

    public func field(_ name: String) -> GraphValue? {
        guard case .object(let entries) = self else { return nil }
        return entries.first { $0.name == name }?.value
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [GraphValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var objectFields: [GraphField]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    public var mapEntries: [GraphMapEntry]? {
        if case .map(let entries) = self { return entries }
        return nil
    }

    static func decode(_ input: Any) throws -> GraphValue {
        if input is NSNull { return .null }
        if let value = input as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        }
        if let value = input as? String { return .string(value) }
        if let array = input as? [Any] { return .array(try array.map(decode)) }
        guard let object = input as? [String: Any] else {
            throw GraphDiagnostic.invalid("unsupported JSON value \(type(of: input))")
        }
        if let tag = object["$type"] as? String {
            switch tag {
            case "undefined": return .undefined
            case "number":
                switch object["value"] as? String {
                case "-0": return .number(-0.0)
                case "NaN": return .number(.nan)
                case "Infinity": return .number(.infinity)
                case "-Infinity": return .number(-.infinity)
                default: throw GraphDiagnostic.unsupported("unknown tagged number")
                }
            case "object":
                guard let entries = object["entries"] as? [[Any]] else {
                    throw GraphDiagnostic.invalid("tagged object lacks entries")
                }
                return .object(try entries.map { item in
                    guard item.count == 2, let key = item[0] as? String else {
                        throw GraphDiagnostic.invalid("malformed tagged object entry")
                    }
                    return GraphField(name: key, value: try decode(item[1]))
                })
            case "map":
                guard let entries = object["entries"] as? [[Any]] else {
                    throw GraphDiagnostic.invalid("tagged map lacks entries")
                }
                return .map(try entries.map { item in
                    guard item.count == 2 else { throw GraphDiagnostic.invalid("malformed tagged map entry") }
                    return GraphMapEntry(key: try decode(item[0]), value: try decode(item[1]))
                })
            default:
                return .tagged(tag, try object.keys.filter { $0 != "$type" }.sorted().map {
                    GraphField(name: $0, value: try decode(object[$0]!))
                })
            }
        }
        return .object(try object.keys.sorted().map { GraphField(name: $0, value: try decode(object[$0]!)) })
    }
}
