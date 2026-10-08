import Foundation

/// Decodes user-supplied Portable JSON without losing object insertion order.
/// JavaScript's registration and expansion paths enumerate those keys in source order.
enum OrderedJSON {
    static func decode(_ data: Data) throws -> GraphValue {
        var scanner = Scanner(bytes: Array(data))
        let value = try scanner.value()
        scanner.skipWhitespace()
        guard scanner.atEnd else { throw CatalogError.malformed("trailing Portable JSON") }
        return value
    }

    private struct Scanner {
        let bytes: [UInt8]
        var offset = 0
        var atEnd: Bool { offset == bytes.count }

        mutating func skipWhitespace() {
            while offset < bytes.count && [UInt8(32), 9, 10, 13].contains(bytes[offset]) {
                offset += 1
            }
        }

        mutating func value() throws -> GraphValue {
            skipWhitespace()
            guard offset < bytes.count else { throw CatalogError.malformed("truncated Portable JSON") }
            switch bytes[offset] {
            case 123: return try object()
            case 91: return try array()
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            default: return try number()
            }
        }

        private mutating func object() throws -> GraphValue {
            offset += 1
            skipWhitespace()
            var fields: [GraphField] = []
            if try consume(125) { return .object(fields) }
            while true {
                let key = try string()
                skipWhitespace()
                guard try consume(58) else { throw CatalogError.malformed("expected colon in Portable JSON") }
                let child = try value()
                if let existing = fields.firstIndex(where: { $0.name == key }) {
                    fields[existing] = GraphField(name: key, value: child)
                } else {
                    fields.append(GraphField(name: key, value: child))
                }
                skipWhitespace()
                if try consume(125) { return .object(fields) }
                guard try consume(44) else { throw CatalogError.malformed("expected comma in Portable JSON object") }
                skipWhitespace()
            }
        }

        private mutating func array() throws -> GraphValue {
            offset += 1
            skipWhitespace()
            var items: [GraphValue] = []
            if try consume(93) { return .array(items) }
            while true {
                items.append(try value())
                skipWhitespace()
                if try consume(93) { return .array(items) }
                guard try consume(44) else { throw CatalogError.malformed("expected comma in Portable JSON array") }
            }
        }

        private mutating func string() throws -> String {
            guard try consume(34) else { throw CatalogError.malformed("expected Portable JSON string") }
            let start = offset - 1
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if byte == 92 {
                    guard offset < bytes.count else { throw CatalogError.malformed("truncated Portable JSON escape") }
                    offset += 1
                } else if byte == 34 {
                    let slice = Data(bytes[start..<offset])
                    guard let decoded = try JSONSerialization.jsonObject(with: slice, options: .fragmentsAllowed) as? String else {
                        throw CatalogError.malformed("invalid Portable JSON string")
                    }
                    return decoded
                }
            }
            throw CatalogError.malformed("unterminated Portable JSON string")
        }

        private mutating func number() throws -> GraphValue {
            let start = offset
            while offset < bytes.count && [UInt8(45), 43, 46, 69, 101].contains(bytes[offset]) ||
                    (offset < bytes.count && bytes[offset] >= 48 && bytes[offset] <= 57) {
                offset += 1
            }
            guard offset > start, let text = String(bytes: bytes[start..<offset], encoding: .utf8),
                  let number = Double(text), number.isFinite,
                  (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) is NSNumber else {
                throw CatalogError.malformed("invalid Portable JSON number")
            }
            return .number(number)
        }

        private mutating func literal(_ text: String) throws {
            let expected = Array(text.utf8)
            guard offset + expected.count <= bytes.count,
                  Array(bytes[offset..<(offset + expected.count)]) == expected else {
                throw CatalogError.malformed("invalid Portable JSON literal")
            }
            offset += expected.count
        }

        private mutating func consume(_ byte: UInt8) throws -> Bool {
            guard offset < bytes.count else { throw CatalogError.malformed("truncated Portable JSON") }
            if bytes[offset] != byte { return false }
            offset += 1
            return true
        }
    }
}
