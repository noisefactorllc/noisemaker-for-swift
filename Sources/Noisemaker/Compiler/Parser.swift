import Foundation
import CoreFoundation

public struct ParserField: Equatable, Sendable {
    public let name: String
    public let value: ParserValue
}

/// An ordered AST value. Object field order and explicit undefined values are
/// retained because both occur in the locked JavaScript parser's output.
public struct ParserValue: Equatable, Sendable {
    fileprivate indirect enum Storage: Equatable, Sendable {
        case undefined, null, bool(Bool), number(Double), specialNumber(String)
        case string(String), taggedFunction(String), array([ParserValue]), object([ParserField])
    }

    fileprivate let storage: Storage
    let sourcePosition: SourcePosition?
    public let subchainArgumentDiagnostics: [ParserDiagnostic]

    fileprivate init(_ storage: Storage, position: SourcePosition? = nil,
                     subchainArgumentDiagnostics: [ParserDiagnostic] = []) {
        self.storage = storage
        self.sourcePosition = position
        self.subchainArgumentDiagnostics = subchainArgumentDiagnostics
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage == rhs.storage }

    public var fields: [ParserField]? {
        if case .object(let fields) = storage { return fields }
        return nil
    }
    public var elements: [ParserValue]? {
        if case .array(let elements) = storage { return elements }
        return nil
    }
    public func field(_ name: String) -> ParserValue? { fields?.first { $0.name == name }?.value }
    public var string: String? { if case .string(let value) = storage { return value }; return nil }
    public var number: Double? {
        switch storage {
        case .number(let value): return value
        case .specialNumber("-0"): return -0.0
        case .specialNumber("Infinity"): return .infinity
        case .specialNumber("-Infinity"): return -.infinity
        case .specialNumber("NaN"): return .nan
        default: return nil
        }
    }
    public var bool: Bool? { if case .bool(let value) = storage { return value }; return nil }
    public var type: String? { field("type")?.string }
    public var isNull: Bool { if case .null = storage { return true }; return false }
    public var isUndefined: Bool { if case .undefined = storage { return true }; return false }

    static let undefined = Self(.undefined)
    static let null = Self(.null)
    static func bool(_ value: Bool) -> Self { Self(.bool(value)) }
    static func number(_ value: Double) -> Self {
        if value.isNaN { return Self(.specialNumber("NaN")) }
        if value == .infinity { return Self(.specialNumber("Infinity")) }
        if value == -.infinity { return Self(.specialNumber("-Infinity")) }
        if value == 0 && value.sign == .minus { return Self(.specialNumber("-0")) }
        return Self(.number(value))
    }
    static func string(_ value: String) -> Self { Self(.string(value)) }
    static func taggedFunction(_ source: String) -> Self { Self(.taggedFunction(source)) }
    static func array(_ value: [Self]) -> Self { Self(.array(value)) }
    static func object(_ fields: [(String, Self)], position: SourcePosition? = nil,
                                   subchainArgumentDiagnostics: [ParserDiagnostic] = []) -> Self {
        Self(.object(fields.map { ParserField(name: $0.0, value: $0.1) }), position: position,
             subchainArgumentDiagnostics: subchainArgumentDiagnostics)
    }
    func adding(_ name: String, _ value: Self) -> Self {
        guard case .object(let fields) = storage else { return self }
        return Self(.object(fields + [ParserField(name: name, value: value)]), position: sourcePosition,
                    subchainArgumentDiagnostics: subchainArgumentDiagnostics)
    }

    public func collectSubchainArgumentDiagnostics() -> [ParserDiagnostic] {
        var found = subchainArgumentDiagnostics
        switch storage {
        case .array(let values):
            for value in values { found += value.collectSubchainArgumentDiagnostics() }
        case .object(let fields):
            for field in fields { found += field.value.collectSubchainArgumentDiagnostics() }
        default: break
        }
        return found
    }

    /// Development parity encoding for the ordered upstream stage contract.
    func taggedValue() -> Any {
        switch storage {
        case .undefined: return ["$type": "undefined"]
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .specialNumber(let value): return ["$type": "number", "value": value]
        case .string(let value): return value
        case .taggedFunction(let source): return ["$type": "function", "source": source]
        case .array(let values): return values.map { $0.taggedValue() }
        case .object(let fields):
            return ["$type": "object", "entries": fields.map { [$0.name, $0.value.taggedValue()] as [Any] }]
        }
    }

    public static func decodeTagged(_ input: Any) throws -> Self {
        if input is NSNull { return .null }
        if let number = input as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let string = input as? String { return .string(string) }
        if let array = input as? [Any] { return .array(try array.map(decodeTagged)) }
        guard let object = input as? [String: Any], let tag = object["$type"] as? String else {
            throw ParserIncomplete("malformed tagged parser oracle")
        }
        switch tag {
        case "undefined": return .undefined
        case "number":
            guard let value = object["value"] as? String else { throw ParserIncomplete("malformed tagged number") }
            return Self(.specialNumber(value))
        case "function":
            guard let source = object["source"] as? String else {
                throw ParserIncomplete("malformed tagged function")
            }
            return .taggedFunction(source)
        case "object":
            guard let entries = object["entries"] as? [[Any]] else { throw ParserIncomplete("malformed tagged object") }
            return .object(try entries.map { entry in
                guard entry.count == 2, let name = entry[0] as? String else {
                    throw ParserIncomplete("malformed tagged field")
                }
                return (name, try decodeTagged(entry[1]))
            })
        default: throw ParserIncomplete("unsupported tagged parser oracle value: \(tag)")
        }
    }
}

public struct ParserDiagnostic: Codable, Equatable, Sendable {
    public let code: String
    public let stage: String
    public let severity: String
    public let message: String
    public let location: SourceLocation?
    public let span: SourceSpan?
}

public struct ParserError: Error, Equatable, Sendable, LocalizedError {
    public let diagnostic: ParserDiagnostic
    public var errorDescription: String? { diagnostic.message }
}

/// A deliberate boundary for grammar not yet ported. No unsupported construct
/// is returned as a plausible but incorrect AST node.
public struct ParserIncomplete: Error, Equatable, Sendable, LocalizedError {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
    public var errorDescription: String? { "Native parser incomplete: \(detail)" }
}

public enum NoisemakerParser {
    public static let builtInNamespaces = [
        "io", "classicNoisedeck", "synth", "mixer", "filter", "render",
        "points", "synth3d", "filter3d", "user"
    ]

    public static func parse(_ source: String, validNamespaces: [String] = builtInNamespaces,
                             strictSubchainArguments: Bool = false) throws -> ParserValue {
        try parse(tokens: NoisemakerLexer.lex(source), validNamespaces: validNamespaces,
                  strictSubchainArguments: strictSubchainArguments)
    }

    public static func parse(tokens: [LexerToken], validNamespaces: [String] = builtInNamespaces,
                             strictSubchainArguments: Bool = false) throws -> ParserValue {
        guard tokens.last?.type == "EOF" else { throw ParserIncomplete("lexer token stream lacks EOF") }
        guard !tokens.dropLast().contains(where: { $0.type == "EOF" }) else {
            throw ParserIncomplete("lexer token stream contains an embedded EOF")
        }
        var parser = Scanner(tokens: tokens, validNamespaces: validNamespaces,
                            strictSubchainArguments: strictSubchainArguments)
        return try parser.parseProgram()
    }

    private struct Scanner {
        let tokens: [LexerToken]
        let validNamespaces: [String]
        let strictSubchainArguments: Bool
        var current = 0
        var searchOrder: [String]? = nil

        private var token: LexerToken { tokens[min(current, tokens.count - 1)] }
        private func look(_ distance: Int) -> LexerToken? {
            let offset = current + distance
            return offset < tokens.count ? tokens[offset] : nil
        }
        @discardableResult private mutating func advance() -> LexerToken {
            let result = token
            current += 1
            return result
        }
        private func error(_ code: String, _ message: String, _ at: LexerToken? = nil,
                           node: ParserValue? = nil, severity: String = "error") -> ParserError {
            let found = at
            let position = found?.position ?? node?.sourcePosition
            let legacyLoc = node?.field("loc")
            let location = position.flatMap { $0.line > 0 && $0.column > 0 && $0.start >= 0 && $0.end >= $0.start
                ? SourceLocation(line: $0.line, column: $0.column) : nil }
                ?? (found.flatMap { $0.line > 0 && $0.col > 0
                    ? SourceLocation(line: $0.line, column: $0.col) : nil })
                ?? (legacyLoc.flatMap { loc -> SourceLocation? in
                    guard let line = loc.field("line")?.number, let col = loc.field("col")?.number else { return nil }
                    return SourceLocation(line: Int(line), column: Int(col))
                })
            let span = position.flatMap { $0.line > 0 && $0.column > 0 && $0.start >= 0 && $0.end >= $0.start
                ? SourceSpan(start: $0.start, end: $0.end) : nil }
            return ParserError(diagnostic: ParserDiagnostic(code: code, stage: "parser", severity: severity,
                                                             message: message, location: location, span: span))
        }
        @discardableResult private mutating func expect(_ type: String, _ message: String) throws -> LexerToken {
            if token.type == type { return advance() }
            throw error(type == "RPAREN" ? "P002" : "P001",
                        "\(message) at line \(token.line) col \(token.col)", token)
        }
        private mutating func collectComments() -> [String] {
            var comments: [String] = []
            while token.type == "COMMENT" { comments.append(advance().lexeme) }
            return comments
        }
        private static let expressionStarts: Set<String> = [
            "PLUS", "MINUS", "NUMBER", "HEX", "FUNC", "STRING", "IDENT", "OUTPUT_REF",
            "SOURCE_REF", "VOL_REF", "GEO_REF", "MESH_REF", "XYZ_REF", "VEL_REF", "RGBA_REF",
            "LPAREN", "LBRACKET", "TRUE", "FALSE"
        ]
        private static let memberTypes: Set<String> = [
            "IDENT", "SOURCE_REF", "OUTPUT_REF", "VOL_REF", "GEO_REF", "MESH_REF",
            "XYZ_REF", "VEL_REF", "RGBA_REF", "LET", "RENDER", "TRUE", "FALSE", "IF",
            "ELIF", "ELSE", "BREAK", "CONTINUE", "RETURN", "WRITE", "WRITE3D", "SUBCHAIN"
        ]
        private static let namespaceTypes: Set<String> = [
            "IDENT", "RENDER", "WRITE", "WRITE3D", "TRUE", "FALSE", "IF", "ELIF", "ELSE",
            "BREAK", "CONTINUE", "RETURN"
        ]

        private func node(_ type: String, _ name: String) -> ParserValue {
            .object([("type", .string(type)), ("name", .string(name))])
        }
        private func loc(_ at: LexerToken) -> ParserValue {
            .object([("line", .number(Double(at.line))), ("col", .number(Double(at.col)))])
        }

        mutating func parseProgram() throws -> ParserValue {
            guard !tokens.isEmpty else { throw ParserIncomplete("lexer token stream is empty") }
            var plans: [ParserValue] = []
            var vars: [ParserValue] = []
            var render: ParserValue = .null
            var trailingComments: [String] = []

            while token.type != "EOF" {
                if token.type == "SEMICOLON" { advance(); continue }
                let leading = collectComments()
                if token.type == "EOF" { trailingComments += leading; break }
                if token.type == "SEMICOLON" { continue }
                if token.type == "SEARCH" {
                    if !plans.isEmpty || !vars.isEmpty || render != .null {
                        throw error("P004", "'search' directive must appear before other statements at line \(token.line) col \(token.col)", token)
                    }
                    try parseSearchDirective()
                    continue
                }
                if token.type == "RENDER" {
                    render = try parseRenderDirective()
                    if !leading.isEmpty { render = render.adding("leadingComments", .array(leading.map { .string($0) })) }
                    trailingComments += collectComments()
                    break
                }
                var statement = try parseStatement()
                if !leading.isEmpty { statement = statement.adding("leadingComments", .array(leading.map { .string($0) })) }
                if statement.type == "VarAssign" { vars.append(statement) }
                else { plans.append(statement) }
                while token.type == "SEMICOLON" { advance() }
            }
            let eof = try expect("EOF", "Expected end of input")
            guard let searchOrder, !searchOrder.isEmpty else {
                throw error("P004", "Missing required 'search' directive. Every program must start with 'search <namespace>, ...' to specify namespace search order.", eof)
            }
            var fields: [(String, ParserValue)] = [("type", .string("Program")), ("plans", .array(plans)), ("render", render)]
            if !vars.isEmpty { fields.append(("vars", .array(vars))) }
            if !trailingComments.isEmpty { fields.append(("trailingComments", .array(trailingComments.map { .string($0) }))) }
            let imports = searchOrder.map { name in
                ParserValue.object([("name", .string(name)), ("source", .string("search")), ("explicit", .bool(true))])
            }
            let namespace = ParserValue.object([
                ("imports", .array(imports)), ("default", imports[0]),
                ("searchOrder", .array(searchOrder.map { .string($0) }))
            ])
            fields.append(("namespace", namespace))
            return .object(fields)
        }

        private mutating func parseSearchDirective() throws {
            if searchOrder != nil {
                throw error("P004", "Only one search directive is allowed per program at line \(token.line) col \(token.col)", token)
            }
            advance()
            guard Self.namespaceTypes.contains(token.type) else {
                throw error("P004", "Expected namespace identifier after search at line \(token.line) col \(token.col)", token)
            }
            var names: [String] = []
            while true {
                let found = advance()
                if !validNamespaces.contains(found.lexeme) {
                    throw error("P004", "Invalid namespace '\(found.lexeme)' at line \(found.line) col \(found.col). Valid namespaces: \(validNamespaces.joined(separator: ", "))", found)
                }
                names.append(found.lexeme)
                if token.type != "COMMA" { break }
                advance()
                guard Self.namespaceTypes.contains(token.type) else {
                    throw error("P004", "Expected namespace identifier after comma at line \(token.line) col \(token.col)", token)
                }
            }
            searchOrder = names
            while token.type == "SEMICOLON" { advance() }
        }

        private mutating func parseRenderDirective() throws -> ParserValue {
            advance()
            try expect("LPAREN", "Expect '('")
            if token.type != "OUTPUT_REF" { throw error("P005", "Expected output reference in render()", token) }
            let output = node("OutputRef", advance().lexeme)
            try expect("RPAREN", "Expect ')'")
            while token.type == "SEMICOLON" { advance() }
            return output
        }

        private mutating func parseBlock() throws -> [ParserValue] {
            try expect("LBRACE", "Expect '{'")
            var body: [ParserValue] = []
            while token.type != "RBRACE" {
                if token.type == "EOF" { throw ParserIncomplete("upstream parser does not terminate on EOF inside a block") }
                body.append(try parseStatement())
                while token.type == "SEMICOLON" { advance() }
            }
            try expect("RBRACE", "Expect '}'")
            return body
        }

        private mutating func parseStatement() throws -> ParserValue {
            if token.type == "SEARCH" {
                throw error("P004", "'search' directive is only allowed at the start of the program at line \(token.line) col \(token.col)", token)
            }
            if token.type == "LET" {
                advance()
                let name = try expect("IDENT", "Expected identifier").lexeme
                try expect("EQUAL", "Expect '='")
                if !Self.expressionStarts.contains(token.type) {
                    throw error("P001", "Expected expression after '=' at line \(token.line) col \(token.col)", token)
                }
                return .object([("type", .string("VarAssign")), ("name", .string(name)),
                                ("expr", try parseAdditive())])
            }
            if token.type == "IF" {
                advance()
                try expect("LPAREN", "Expect '('")
                let condition = try parseAdditive()
                try expect("RPAREN", "Expect ')'")
                let then = try parseBlock()
                var elif: [ParserValue] = []
                while token.type == "ELIF" {
                    advance()
                    try expect("LPAREN", "Expect '('")
                    let ec = try parseAdditive()
                    try expect("RPAREN", "Expect ')'")
                    let body = try parseBlock()
                    elif.append(.object([("condition", ec), ("then", .array(body))]))
                }
                var elseBranch: ParserValue = .null
                if token.type == "ELSE" { advance(); elseBranch = .array(try parseBlock()) }
                return .object([("type", .string("IfStmt")), ("condition", condition),
                                ("then", .array(then)), ("elif", .array(elif)), ("else", elseBranch)])
            }
            if token.type == "BREAK" { advance(); return .object([("type", .string("Break"))]) }
            if token.type == "CONTINUE" { advance(); return .object([("type", .string("Continue"))]) }
            if token.type == "RETURN" {
                advance()
                var result = ParserValue.object([("type", .string("Return"))])
                if Self.expressionStarts.contains(token.type) { result = result.adding("value", try parseAdditive()) }
                return result
            }
            let chain = try parseChain()
            let last = chain.last
            var write: ParserValue = .null
            var write3d: ParserValue = .null
            if last?.type == "Write" { write = last?.field("surface") ?? .null }
            if last?.type == "Write3D" {
                write3d = .object([("tex3d", last?.field("tex3d") ?? .null),
                                   ("geo", last?.field("geo") ?? .null)])
            }
            return .object([("chain", .array(chain)), ("write", write), ("write3d", write3d)])
        }

        private mutating func parseChain(expression: Bool = false) throws -> [ParserValue] {
            var calls = [try parseCall()]
            while true {
                let saved = current
                let leading = collectComments()
                if token.type != "DOT" { current = saved; break }
                advance()
                let comments = leading + collectComments()
                var next: ParserValue
                if token.type == "WRITE" || token.type == "WRITE3D" {
                    if expression {
                        throw error("P005", "'.write()' is only allowed in statement context at line \(token.line) col \(token.col)", token)
                    }
                    next = try parseWriteCall()
                } else if token.type == "SUBCHAIN" {
                    next = try parseSubchainCall()
                } else {
                    next = try parseCall()
                }
                if !comments.isEmpty { next = next.adding("leadingComments", .array(comments.map { .string($0) })) }
                calls.append(next)
            }
            return calls
        }

        private mutating func parseWriteCall() throws -> ParserValue {
            let nameToken = token
            if token.type == "WRITE" {
                advance()
                try expect("LPAREN", "Expect '('")
                let surface: ParserValue
                let types = ["OUTPUT_REF": "OutputRef", "XYZ_REF": "XyzRef", "VEL_REF": "VelRef",
                             "RGBA_REF": "RgbaRef", "MESH_REF": "MeshRef"]
                if let type = types[token.type] { surface = node(type, advance().lexeme) }
                else if token.type == "IDENT" && token.lexeme == "none" {
                    surface = node("OutputRef", advance().lexeme)
                } else {
                    throw error("P005", "write() requires an explicit surface reference (e.g., o0, o1, xyz0, vel0, rgba0, mesh0, none) at line \(token.line) col \(token.col)", token)
                }
                try expect("RPAREN", "Expect ')'")
                return .object([("type", .string("Write")), ("surface", surface), ("loc", loc(nameToken))])
            }
            if token.type == "WRITE3D" {
                advance()
                try expect("LPAREN", "Expect '('")
                let texTypes = ["IDENT": "Ident", "OUTPUT_REF": "OutputRef", "VOL_REF": "VolRef"]
                guard let texType = texTypes[token.type] else {
                    throw error("P005", "Expected tex3d reference in write3d() at line \(token.line) col \(token.col)", token)
                }
                let tex3d = node(texType, advance().lexeme)
                try expect("COMMA", "Expect ',' between tex3d and geo in write3d()")
                let geoTypes = ["IDENT": "Ident", "OUTPUT_REF": "OutputRef", "GEO_REF": "GeoRef"]
                guard let geoType = geoTypes[token.type] else {
                    throw error("P005", "Expected geo reference in write3d() at line \(token.line) col \(token.col)", token)
                }
                let geo = node(geoType, advance().lexeme)
                try expect("RPAREN", "Expect ')'")
                return .object([("type", .string("Write3D")), ("tex3d", tex3d),
                                ("geo", geo), ("loc", loc(nameToken))])
            }
            throw error("P005", "Expected write or write3d at line \(nameToken.line) col \(nameToken.col)", nameToken)
        }

        private mutating func parseSubchainCall() throws -> ParserValue {
            let nameToken = advance()
            try expect("LPAREN", "Expect '(' after subchain")
            var kwargs: [(String, ParserValue)] = []
            var warnings: [ParserDiagnostic] = []
            if token.type != "RPAREN" {
                if token.type == "STRING" {
                    kwargs.append(("name", .object([("type", .string("String")), ("value", .string(advance().lexeme))])))
                } else if token.type == "IDENT" && look(1)?.type == "COLON" {
                    while token.type == "IDENT" && look(1)?.type == "COLON" {
                        let keyToken = advance()
                        advance()
                        if token.type != "STRING" {
                            throw error("P006", "Expected string value for subchain \(keyToken.lexeme) at line \(token.line) col \(token.col)", token)
                        }
                        let value = advance().lexeme
                        if keyToken.lexeme != "name" && keyToken.lexeme != "id" {
                            let message = "Unknown subchain argument '\(keyToken.lexeme)' at line \(keyToken.line) col \(keyToken.col). Valid keys: name, id. The value is discarded."
                            if strictSubchainArguments { throw error("P008", message, keyToken) }
                            warnings.append(error("P008", message, keyToken, severity: "warning").diagnostic)
                        }
                        else if kwargs.contains(where: { $0.0 == keyToken.lexeme }) {
                            let message = "Duplicate subchain argument '\(keyToken.lexeme)' at line \(keyToken.line) col \(keyToken.col). The last value wins."
                            if strictSubchainArguments { throw error("P009", message, keyToken) }
                            warnings.append(error("P009", message, keyToken, severity: "warning").diagnostic)
                        }
                        let entry: ParserValue = .object([("type", .string("String")), ("value", .string(value))])
                        if let existing = kwargs.firstIndex(where: { $0.0 == keyToken.lexeme }) { kwargs[existing].1 = entry }
                        else { kwargs.append((keyToken.lexeme, entry)) }
                        if token.type == "COMMA" { advance() }
                        else if token.type == "IDENT" && look(1)?.type == "COLON" {
                            let message = "Missing ',' between subchain arguments at line \(token.line) col \(token.col)"
                            if strictSubchainArguments { throw error("P010", message, token) }
                            warnings.append(error("P010", message, token, severity: "warning").diagnostic)
                        }
                    }
                }
            }
            try expect("RPAREN", "Expect ')' after subchain arguments")
            try expect("LBRACE", "Expect '{' to start subchain body")
            var body: [ParserValue] = []
            while token.type != "RBRACE" {
                if token.type == "EOF" { throw ParserIncomplete("upstream parser does not terminate on EOF inside a subchain") }
                let comments = collectComments()
                if token.type == "RBRACE" { break }
                if token.type != "DOT" {
                    throw error("P006", "Expected '.' before chain element in subchain body at line \(token.line) col \(token.col)", token)
                }
                advance()
                let allComments = comments + collectComments()
                var call = try parseCall()
                if !allComments.isEmpty { call = call.adding("leadingComments", .array(allComments.map { .string($0) })) }
                body.append(call)
            }
            try expect("RBRACE", "Expect '}' to end subchain body")
            if body.isEmpty {
                throw error("P006", "Subchain body cannot be empty at line \(nameToken.line) col \(nameToken.col)", nameToken)
            }
            let name = kwargs.first(where: { $0.0 == "name" })?.1.field("value")?.string
            let id = kwargs.first(where: { $0.0 == "id" })?.1.field("value")?.string
            return .object([("type", .string("Subchain")), ("name", name.map { .string($0) } ?? .null),
                            ("id", id.map { .string($0) } ?? .null), ("body", .array(body)),
                            ("loc", loc(nameToken))], subchainArgumentDiagnostics: warnings)
        }

        private func hasCallAfterDot(_ start: Int) -> Bool {
            var offset = start + 1
            guard offset < tokens.count && tokens[offset].type == "DOT" else { return false }
            while offset < tokens.count && tokens[offset].type == "DOT" {
                guard offset + 1 < tokens.count && Self.memberTypes.contains(tokens[offset + 1].type) else { return false }
                offset += 2
            }
            return offset < tokens.count && tokens[offset].type == "LPAREN"
        }

        private mutating func parseCall() throws -> ParserValue {
            let nameToken = try expect("IDENT", "Expected identifier")
            if token.type == "DOT", let member = look(1), member.type == "IDENT", look(2)?.type == "LPAREN" {
                throw error("P007", "Inline namespace syntax '\(nameToken.lexeme).\(member.lexeme)()' is not allowed. Use 'search \(nameToken.lexeme)' at the start of the program instead, at line \(nameToken.line) col \(nameToken.col)", nameToken)
            }
            try expect("LPAREN", "Expect '('")
            var args: [ParserValue] = []
            var kwargs: [(String, ParserValue)] = []
            var keyword = false
            var positional = false
            let allowMixed = nameToken.lexeme == "midi" || nameToken.lexeme == "audio"
            if token.type != "RPAREN" {
                while true {
                    if token.type == "IDENT" && look(1)?.type == "COLON" {
                        if positional && !allowMixed {
                            throw error("P007", "Cannot mix positional and keyword arguments at line \(token.line) col \(token.col)", token)
                        }
                        keyword = true
                        let key = advance().lexeme
                        try expect("COLON", "Expect ':'")
                        if !Self.expressionStarts.contains(token.type) {
                            throw error("P001", "Expected expression after '=' at line \(token.line) col \(token.col)", token)
                        }
                        let value = try parseAdditive()
                        if let existing = kwargs.firstIndex(where: { $0.0 == key }) { kwargs[existing].1 = value }
                        else { kwargs.append((key, value)) }
                    } else {
                        if keyword && !allowMixed {
                            throw error("P007", "Cannot mix positional and keyword arguments at line \(token.line) col \(token.col)", token)
                        }
                        positional = true
                        args.append(try parseAdditive())
                    }
                    if token.type != "COMMA" { break }
                    advance()
                    if token.type == "RPAREN" { break }
                }
            }
            try expect("RPAREN", "Expect ')'")
            var fields: [(String, ParserValue)] = [("type", .string("Call")), ("name", .string(nameToken.lexeme)),
                                                   ("args", .array(args))]
            if keyword { fields.append(("kwargs", .object(kwargs))) }
            let call = ParserValue.object(fields)
            if nameToken.lexeme == "from" { return try transformFrom(call, args, kwargs, nameToken) }
            if nameToken.lexeme == "osc" {
                let oscKeys: Set<String> = ["type", "min", "max", "speed", "offset", "seed"]
                let firstKind = args.first?.type == "Member" && args.first?.field("path")?.elements?.first?.string == "oscKind"
                let bare = args.isEmpty && kwargs.isEmpty
                let onlyOscKwargs = !kwargs.isEmpty && kwargs.allSatisfy { oscKeys.contains($0.0) }
                if kwargs.contains(where: { $0.0 == "type" }) || firstKind || bare || onlyOscKwargs {
                    return try transformOsc(args, kwargs, nameToken)
                }
            }
            if nameToken.lexeme == "midi" { return try transformMidi(args, kwargs, nameToken) }
            if nameToken.lexeme == "audio" { return try transformAudio(args, kwargs, nameToken) }
            if nameToken.lexeme == "read" {
                let surface = args.first ?? kwargs.first(where: { $0.0 == "tex" })?.1
                    ?? kwargs.first(where: { $0.0 == "surface" })?.1 ?? .undefined
                var result = ParserValue.object([("type", .string("Read")), ("surface", surface),
                                                 ("loc", loc(nameToken))])
                if kwargs.first(where: { $0.0 == "_skip" })?.1.type == "Boolean" &&
                    kwargs.first(where: { $0.0 == "_skip" })?.1.field("value")?.bool == true {
                    result = result.adding("_skip", .bool(true))
                }
                return result
            }
            if nameToken.lexeme == "read3d" {
                let tex3d = args.first ?? kwargs.first(where: { $0.0 == "tex3d" })?.1 ?? .undefined
                let geo = (args.count > 1 ? args[1] : nil) ?? kwargs.first(where: { $0.0 == "geo" })?.1 ?? .null
                var result = ParserValue.object([("type", .string("Read3D")), ("tex3d", tex3d),
                                                 ("geo", geo), ("loc", loc(nameToken))])
                if kwargs.first(where: { $0.0 == "_skip" })?.1.type == "Boolean" &&
                    kwargs.first(where: { $0.0 == "_skip" })?.1.field("value")?.bool == true {
                    result = result.adding("_skip", .bool(true))
                }
                return result
            }
            return call
        }

        private mutating func parseAdditive() throws -> ParserValue {
            var value = try parseMultiplicative()
            while token.type == "PLUS" || token.type == "MINUS" {
                let op = advance().type
                let right = try parseMultiplicative()
                let lhs = try toNumber(value)
                let rhs = try toNumber(right)
                value = .object([("type", .string("Number")),
                                 ("value", .number(op == "PLUS" ? lhs + rhs : lhs - rhs))])
            }
            return value
        }

        private mutating func parseMultiplicative() throws -> ParserValue {
            var value = try parseUnary()
            while token.type == "STAR" || token.type == "SLASH" {
                let op = advance().type
                let right = try parseUnary()
                let lhs = try toNumber(value)
                let rhs = try toNumber(right)
                value = .object([("type", .string("Number")),
                                 ("value", .number(op == "STAR" ? lhs * rhs : lhs / rhs))])
            }
            return value
        }

        private mutating func parseUnary() throws -> ParserValue {
            if token.type == "PLUS" { advance(); return try parseUnary() }
            if token.type == "MINUS" {
                advance()
                let value = try parseUnary()
                return .object([("type", .string("Number")), ("value", .number(-(try toNumber(value))))])
            }
            return try parsePrimary()
        }

        private func toNumber(_ value: ParserValue) throws -> Double {
            guard value.type == "Number", let number = value.field("value")?.number else {
                throw error("P001", "Expected number", node: value)
            }
            return number
        }

        private func validNumberLexeme(_ lexeme: String) -> Bool {
            let units = Array(lexeme.utf16)
            guard !units.isEmpty else { return false }
            var index = 0
            if units[index] == 46 { index += 1 }
            let firstDigit = index
            while index < units.count && (48...57).contains(units[index]) { index += 1 }
            guard index > firstDigit else { return false }
            if firstDigit == 0 && index < units.count && units[index] == 46 {
                index += 1
                let fractionalDigit = index
                while index < units.count && (48...57).contains(units[index]) { index += 1 }
                guard index > fractionalDigit else { return false }
            }
            return index == units.count
        }

        private mutating func parsePrimary() throws -> ParserValue {
            let found = token
            switch found.type {
            case "NUMBER":
                guard validNumberLexeme(found.lexeme), let value = Double(found.lexeme) else {
                    throw ParserIncomplete("NUMBER token has an invalid numeric lexeme")
                }
                advance()
                return .object([("type", .string("Number")), ("value", .number(value))])
            case "STRING":
                advance()
                return .object([("type", .string("String")), ("value", .string(found.lexeme))])
            case "HEX":
                let hex = Array(found.lexeme.utf16)
                guard [4, 7, 9].contains(hex.count), hex.first == 35,
                      hex.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                    throw ParserIncomplete("HEX token has an invalid color lexeme")
                }
                advance()
                let units = Array(found.lexeme.dropFirst())
                func pair(_ start: Int, _ count: Int) throws -> Double {
                    let text = count == 1 ? String(repeating: String(units[start]), count: 2)
                        : String(units[start..<(start + count)])
                    guard let value = Int(text, radix: 16) else {
                        throw ParserIncomplete("HEX token has an invalid color lexeme")
                    }
                    return Double(value)
                }
                let short = units.count == 3
                let width = short ? 1 : 2
                let alpha = units.count == 8 ? try pair(6, 2) / 255 : 1.0
                let red = try pair(0, width) / 255
                let green = try pair(width, width) / 255
                let blue = try pair(width * 2, width) / 255
                return .object([("type", .string("Color")), ("value", .array([
                    .number(red), .number(green), .number(blue), .number(alpha)
                ]))])
            case "LBRACKET":
                advance()
                var elements: [ParserValue] = []
                if token.type != "RBRACKET" {
                    elements.append(try parseAdditive())
                    while token.type == "COMMA" { advance(); elements.append(try parseAdditive()) }
                }
                if token.type != "RBRACKET" {
                    throw error("P001", "Expected ']' at line \(token.line) col \(token.col)", token)
                }
                advance()
                return .object([("type", .string("ArrayLiteral")), ("elements", .array(elements)),
                                ("loc", loc(found))], position: found.position)
            case "FUNC": advance(); return .object([("type", .string("Func")), ("src", .string(found.lexeme))])
            case "TRUE": advance(); return .object([("type", .string("Boolean")), ("value", .bool(true))])
            case "FALSE": advance(); return .object([("type", .string("Boolean")), ("value", .bool(false))])
            case "IDENT":
                if found.lexeme == "Math" && look(1)?.type == "DOT" && look(2)?.lexeme == "PI" {
                    advance(); advance(); advance()
                    return .object([("type", .string("Number")), ("value", .number(.pi))])
                }
                if look(1)?.type == "LPAREN" || hasCallAfterDot(current) {
                    let chain = try parseChain(expression: true)
                    return chain.count == 1 ? chain[0] : .object([("type", .string("Chain")), ("chain", .array(chain))])
                }
                advance()
                var path = [found.lexeme]
                while token.type == "DOT" {
                    guard let next = look(1) else { break }
                    if look(2)?.type == "LPAREN" { break }
                    if !Self.memberTypes.contains(next.type) {
                        throw error("P001", "Expected identifier after '.' at line \(next.line) col \(next.col)", next)
                    }
                    advance(); advance(); path.append(next.lexeme)
                }
                if path.count > 1 {
                    return .object([("type", .string("Member")),
                                    ("path", .array(path.map { .string($0) }))])
                }
                return node("Ident", path[0])
            case "OUTPUT_REF", "SOURCE_REF", "VOL_REF", "GEO_REF", "XYZ_REF", "VEL_REF", "RGBA_REF", "MESH_REF":
                advance()
                guard let type = ["OUTPUT_REF": "OutputRef", "SOURCE_REF": "SourceRef", "VOL_REF": "VolRef",
                            "GEO_REF": "GeoRef", "XYZ_REF": "XyzRef", "VEL_REF": "VelRef", "RGBA_REF": "RgbaRef",
                            "MESH_REF": "MeshRef"][found.type] else {
                    throw ParserIncomplete("unknown reference token type")
                }
                return node(type, found.lexeme)
            case "LPAREN":
                advance()
                let expression = try parseAdditive()
                try expect("RPAREN", "Expect ')'")
                return expression
            default:
                throw error("P001", "Unexpected token \(found.type) at line \(found.line) col \(found.col)", found)
            }
        }

        private func keyword(_ name: String, _ kwargs: [(String, ParserValue)]) -> ParserValue? {
            kwargs.first { $0.0 == name }?.1
        }

        private func defaultNumber(_ value: Double) -> ParserValue {
            .object([("type", .string("Number")), ("value", .number(value))])
        }

        private func defaultMember(_ path: [String]) -> ParserValue {
            .object([("type", .string("Member")), ("path", .array(path.map { .string($0) }))])
        }

        private func resolve(_ name: String, _ index: Int, _ args: [ParserValue],
                             _ kwargs: [(String, ParserValue)], fallback: ParserValue = .undefined) -> ParserValue {
            keyword(name, kwargs) ?? (index < args.count ? args[index] : fallback)
        }

        private func transformOsc(_ args: [ParserValue], _ kwargs: [(String, ParserValue)],
                                  _ at: LexerToken) throws -> ParserValue {
            let order = ["type", "min", "max", "speed", "offset", "seed"]
            for (key, _) in kwargs where !order.contains(key) {
                throw error("P003", "osc() unknown parameter '\(key)' at line \(at.line) col \(at.col). Valid: \(order.joined(separator: ", "))", at)
            }
            let defaults = [defaultMember(["oscKind", "sine"]), defaultNumber(0), defaultNumber(1),
                            defaultNumber(1), defaultNumber(0), defaultNumber(1)]
            let resolved = order.enumerated().map { index, name in
                resolve(name, index, args, kwargs, fallback: defaults[index])
            }
            return .object([("type", .string("Oscillator")), ("oscType", resolved[0]),
                            ("min", resolved[1]), ("max", resolved[2]), ("speed", resolved[3]),
                            ("offset", resolved[4]), ("seed", resolved[5]), ("loc", loc(at))])
        }

        private func transformFrom(_ call: ParserValue, _ args: [ParserValue],
                                   _ kwargs: [(String, ParserValue)], _ at: LexerToken) throws -> ParserValue {
            func fail(_ message: String) -> ParserError {
                error("P007", "\(message) at line \(at.line) col \(at.col)", at)
            }
            if !kwargs.isEmpty { throw fail("'from' does not support named arguments") }
            if args.count != 2 { throw fail("'from' requires exactly two arguments (namespace, call)") }
            let namespaceArg = args[0]
            if namespaceArg.type != "Ident" && namespaceArg.type != "Member" {
                throw fail("'from' namespace argument must be an identifier")
            }
            let name = namespaceArg.type == "Member"
                ? (namespaceArg.field("path")?.elements?.compactMap(\.string).joined(separator: ".") ?? "")
                : (namespaceArg.field("name")?.string ?? "")
            if name.isEmpty { throw fail("'from' namespace argument must be non-empty") }
            let target = args[1]
            let targetCall = target.type == "Call" ? target
                : (target.type == "Chain" && target.field("chain")?.elements?.count == 1
                   ? target.field("chain")?.elements?.first : nil)
            guard let targetCall, targetCall.type == "Call" else {
                throw fail("'from' second argument must be a call expression")
            }
            let namespace = ParserValue.object([
                ("name", .string(name)), ("path", .array([.string(name)])),
                ("explicit", .bool(true)), ("source", .string("from")),
                ("resolved", .string(name)), ("searchOrder", .array([.string(name)])),
                ("fromOverride", .bool(true))
            ])
            return targetCall.adding("namespace", namespace)
        }

        private func transformMidi(_ args: [ParserValue], _ kwargs: [(String, ParserValue)],
                                   _ at: LexerToken) throws -> ParserValue {
            let order = ["channel", "mode", "min", "max", "sensitivity"]
            let valid = order + ["name", "id", "cc", "nrpn", "zone", "members"]
            if args.count > order.count {
                throw error("P003", "midi() name, id, cc, nrpn, zone and members are keyword-only at line \(at.line) col \(at.col)", at)
            }
            for (key, _) in kwargs where !valid.contains(key) {
                throw error("P003", "midi() unknown parameter '\(key)' at line \(at.line) col \(at.col). Valid: \(valid.joined(separator: ", "))", at)
            }
            let defaults: [String: ParserValue] = [
                "mode": defaultMember(["midiMode", "velocity"]), "min": defaultNumber(0),
                "max": defaultNumber(1), "sensitivity": defaultNumber(1)
            ]
            var resolved: [String: ParserValue] = [:]
            var cursor = 0
            for name in order {
                if let value = keyword(name, kwargs) { resolved[name] = value }
                else if cursor < args.count { resolved[name] = args[cursor]; cursor += 1 }
                else if let value = defaults[name] { resolved[name] = value }
            }
            if cursor < args.count {
                throw error("P003", "midi() has an excess positional argument at line \(at.line) col \(at.col)", at)
            }
            let hasChannel = resolved["channel"] != nil
            let hasZone = keyword("zone", kwargs) != nil
            if !hasChannel && !hasZone {
                throw error("P003", "midi() requires 'channel' or 'zone' argument at line \(at.line) col \(at.col)", at)
            }
            if hasChannel && hasZone {
                throw error("P003", "midi() 'channel' and 'zone' are mutually exclusive at line \(at.line) col \(at.col)", at)
            }
            if keyword("members", kwargs) != nil && !hasZone {
                throw error("P003", "midi() 'members' requires 'zone' at line \(at.line) col \(at.col)", at)
            }
            if keyword("id", kwargs) != nil && keyword("name", kwargs) == nil {
                throw error("P003", "midi() 'id' requires readable 'name' at line \(at.line) col \(at.col)", at)
            }
            for name in ["name", "id"] {
                guard let value = keyword(name, kwargs) else { continue }
                if value.type != "String" {
                    throw error("P003", "midi() '\(name)' requires a quoted string at line \(at.line) col \(at.col)", at)
                }
                if value.field("value")?.string?.isEmpty == true {
                    throw error("P003", "midi() '\(name)' must not be empty at line \(at.line) col \(at.col)", at)
                }
            }
            var fields: [(String, ParserValue)] = [("type", .string("Midi"))]
            for name in ["channel", "mode", "min", "max", "sensitivity"] {
                fields.append((name, resolved[name] ?? .undefined))
            }
            for name in ["cc", "nrpn", "zone", "members", "name", "id"] {
                fields.append((name, keyword(name, kwargs) ?? .undefined))
            }
            fields.append(("loc", loc(at)))
            return .object(fields)
        }

        private func transformAudio(_ args: [ParserValue], _ kwargs: [(String, ParserValue)],
                                    _ at: LexerToken) throws -> ParserValue {
            let order = ["band", "min", "max"]
            let valid = order + ["channel", "name", "id"]
            if args.count > order.count {
                throw error("P003", "audio() channel, name and id are keyword-only at line \(at.line) col \(at.col)", at)
            }
            for (key, _) in kwargs where !valid.contains(key) {
                throw error("P003", "audio() unknown parameter '\(key)' at line \(at.line) col \(at.col). Valid: \(valid.joined(separator: ", "))", at)
            }
            let defaults: [String: ParserValue] = ["min": defaultNumber(0), "max": defaultNumber(1)]
            var resolved: [String: ParserValue] = [:]
            var cursor = 0
            for name in order {
                if let value = keyword(name, kwargs) { resolved[name] = value }
                else if cursor < args.count { resolved[name] = args[cursor]; cursor += 1 }
                else if let value = defaults[name] { resolved[name] = value }
            }
            if cursor < args.count {
                throw error("P003", "audio() has an excess positional argument at line \(at.line) col \(at.col)", at)
            }
            if resolved["band"] == nil {
                throw error("P003", "audio() requires 'band' argument at line \(at.line) col \(at.col)", at)
            }
            if keyword("id", kwargs) != nil && keyword("name", kwargs) == nil {
                throw error("P003", "audio() 'id' requires readable 'name' at line \(at.line) col \(at.col)", at)
            }
            if keyword("name", kwargs) != nil && keyword("channel", kwargs) == nil {
                throw error("P003", "audio() selected device requires both 'name' and 'channel' at line \(at.line) col \(at.col)", at)
            }
            for name in ["name", "id"] {
                guard let value = keyword(name, kwargs) else { continue }
                if value.type != "String" {
                    throw error("P003", "audio() '\(name)' requires a quoted string at line \(at.line) col \(at.col)", at)
                }
                if value.field("value")?.string?.isEmpty == true {
                    throw error("P003", "audio() '\(name)' must not be empty at line \(at.line) col \(at.col)", at)
                }
            }
            var fields: [(String, ParserValue)] = [("type", .string("Audio"))]
            for name in ["band", "min", "max"] { fields.append((name, resolved[name] ?? .undefined)) }
            for name in ["channel", "name", "id"] {
                fields.append((name, keyword(name, kwargs) ?? .undefined))
            }
            fields.append(("loc", loc(at)))
            return .object(fields)
        }
    }
}
