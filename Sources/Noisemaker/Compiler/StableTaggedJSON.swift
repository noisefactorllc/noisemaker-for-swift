import CoreFoundation
import Foundation

/// JSONSerialization can print a Double with more digits than needed and then
/// parse that spelling one ULP away. Native graph assembly must retain the
/// compiler's exact Float64 values across its tagged-JSON admission boundary.
enum StableTaggedJSON {
    static func encode(_ value: Any) throws -> Data {
        Data(try string(value).utf8)
    }

    private static func string(_ value: Any) throws -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            guard number.doubleValue.isFinite else {
                throw CompilerIncomplete(stage: "graph", detail: "untagged nonfinite number")
            }
            return String(number.doubleValue)
        }
        if let text = value as? String { return quoted(text) }
        if let array = value as? [Any] {
            return "[" + (try array.map(string)).joined(separator: ",") + "]"
        }
        if let object = value as? [String: Any] {
            let entries = try object.keys.sorted().map { key in
                quoted(key) + ":" + (try string(object[key]!))
            }
            return "{" + entries.joined(separator: ",") + "}"
        }
        throw CompilerIncomplete(stage: "graph", detail: "unsupported tagged JSON value")
    }

    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0..<32: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
