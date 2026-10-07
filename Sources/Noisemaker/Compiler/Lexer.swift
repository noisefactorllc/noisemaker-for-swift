import Foundation

/// The upstream DSL scanner operates on JavaScript UTF-16 string indices.
public enum NoisemakerLexer {
    public static func hashSource(_ source: String) -> String {
        var hash: Int32 = 0
        for unit in source.utf16 {
            hash = hash &* 31 &+ Int32(unit)
        }
        return String(hash, radix: 36)
    }

    public static func lex(_ source: String) throws -> [LexerToken] {
        var scanner = Scanner(source)
        return try scanner.lex()
    }

    private struct Scanner {
        private let units: [UInt16]
        private var tokens: [LexerToken] = []
        private var index = 0
        private var line = 1
        private var col = 1
        private var sourceLine = 1
        private var sourceCol = 1
        private var anchor = 0

        init(_ source: String) { units = Array(source.utf16) }

        private var count: Int { units.count }
        private func unit(_ offset: Int) -> UInt16 { offset < count ? units[offset] : 0 }
        private func slice(_ start: Int, _ end: Int) -> String {
            String(decoding: units[start..<end], as: UTF16.self)
        }
        private func isDigit(_ value: UInt16) -> Bool { value >= 48 && value <= 57 }
        private func isLetter(_ value: UInt16) -> Bool {
            (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
        }
        private func isHex(_ value: UInt16) -> Bool {
            isDigit(value) || (value >= 65 && value <= 70) || (value >= 97 && value <= 102)
        }

        private mutating func advanceSource(_ start: Int, _ end: Int) {
            for offset in start..<end {
                if units[offset] == 10 { sourceLine += 1; sourceCol = 1 }
                else { sourceCol += 1 }
            }
        }

        private mutating func add(_ type: String, _ lexeme: String, _ startLine: Int, _ startCol: Int,
                                  _ end: Int, jsTypeKind: String? = nil) {
            advanceSource(anchor, index)
            let position = SourcePosition(line: sourceLine, column: sourceCol, start: index, end: end)
            advanceSource(index, end)
            anchor = end
            tokens.append(LexerToken(type: type, lexeme: lexeme, line: startLine, col: startCol,
                                     position: position, jsTypeKind: jsTypeKind))
        }

        private func fail(_ code: String, _ message: String, _ start: Int, _ end: Int,
                          messageUTF16: [UInt16]? = nil) -> LexerError {
            var errorLine = 1
            var errorColumn = 1
            for offset in 0..<start {
                if units[offset] == 10 { errorLine += 1; errorColumn = 1 }
                else { errorColumn += 1 }
            }
            return LexerError(diagnostic: LexerDiagnostic(
                code: code, stage: "lexer", severity: "error", message: message,
                messageUTF16: messageUTF16 ?? Array(message.utf16),
                location: SourceLocation(line: errorLine, column: errorColumn),
                span: SourceSpan(start: start, end: end)))
        }

        private static let keywords: [String: String] = [
            "let": "LET", "render": "RENDER", "write": "WRITE", "write3d": "WRITE3D",
            "true": "TRUE", "false": "FALSE", "if": "IF", "elif": "ELIF", "else": "ELSE",
            "break": "BREAK", "continue": "CONTINUE", "return": "RETURN", "search": "SEARCH",
            "subchain": "SUBCHAIN"
        ]

        // RESERVED_KEYWORDS is a plain JavaScript object. These names resolve
        // through Object.prototype rather than becoming IDENT. Swift cannot
        // store a function/object as a token type, so retain its kind and the
        // exact JS string coercion used in parser error messages.
        private static func inheritedKeyword(_ lexeme: String) -> (String, String)? {
            if lexeme == "__proto__" { return ("[object Object]", "object") }
            let names: Set<String> = [
                "constructor", "__defineGetter__", "__defineSetter__", "hasOwnProperty",
                "__lookupGetter__", "__lookupSetter__", "isPrototypeOf",
                "propertyIsEnumerable", "toString", "valueOf", "toLocaleString"
            ]
            guard names.contains(lexeme) else { return nil }
            let displayName = lexeme == "constructor" ? "Object" : lexeme
            return ("function \(displayName)() { [native code] }", "function")
        }

        private func isJSTrimSpace(_ value: UInt16) -> Bool {
            switch value {
            case 9...13, 32, 160, 5760, 8232, 8233, 8239, 8287, 12288, 65279, 8192...8202:
                true
            default:
                false
            }
        }

        mutating func lex() throws -> [LexerToken] {
            while index < count {
                let ch = unit(index)
                if ch == 32 || ch == 9 || ch == 13 { index += 1; col += 1; continue }
                if ch == 10 { index += 1; line += 1; col = 1; continue }

                let startLine = line
                let startCol = col

                if ch == 47 && unit(index + 1) == 47 {
                    var end = index + 2
                    while end < count && unit(end) != 10 { end += 1 }
                    add("COMMENT", slice(index, end), startLine, startCol, end)
                    col += end - index; index = end; continue
                }
                if ch == 47 && unit(index + 1) == 42 {
                    var end = index + 2
                    var endLine = line
                    var endCol = col + 2
                    while end < count && !(unit(end) == 42 && unit(end + 1) == 47) {
                        if unit(end) == 10 { endLine += 1; endCol = 1 }
                        else { endCol += 1 }
                        end += 1
                    }
                    if end >= count {
                        throw fail("L003", "Unterminated comment at line \(startLine) col \(startCol)", index, count)
                    }
                    end += 2
                    add("COMMENT", slice(index, end), startLine, startCol, end)
                    line = endLine; col = endCol + 2; index = end; continue
                }

                if (ch == 111 || ch == 115) && isDigit(unit(index + 1)) {
                    var end = index + 1
                    while end < count && isDigit(unit(end)) { end += 1 }
                    let lexeme = slice(index, end)
                    let type = ch == 111 ? "OUTPUT_REF" : "SOURCE_REF"
                    let member = tokens.last?.type == "DOT"
                    if type == "OUTPUT_REF" && !member && !(end == index + 2 && unit(index + 1) <= 55) {
                        throw fail("L004", "Output surface reference '\(lexeme)' is out of range; expected o0-o7 at line \(startLine) col \(startCol)", index, end)
                    }
                    add(type, lexeme, startLine, startCol, end)
                    col += end - index; index = end; continue
                }

                let references: [(String, String)] = [
                    ("vol", "VOL_REF"), ("geo", "GEO_REF"), ("xyz", "XYZ_REF"),
                    ("vel", "VEL_REF"), ("rgba", "RGBA_REF"), ("mesh", "MESH_REF")
                ]
                var matchedReference = false
                for (prefix, type) in references {
                    let prefixUnits = Array(prefix.utf16)
                    guard index + prefixUnits.count < count,
                          units[index..<(index + prefixUnits.count)].elementsEqual(prefixUnits),
                          isDigit(unit(index + prefixUnits.count)) else { continue }
                    var end = index + prefixUnits.count
                    while end < count && isDigit(unit(end)) { end += 1 }
                    add(type, slice(index, end), startLine, startCol, end)
                    col += end - index; index = end; matchedReference = true
                    break
                }
                if matchedReference { continue }

                if ch == 35 {
                    var end = index + 1
                    while end < count && isHex(unit(end)) { end += 1 }
                    if [4, 7, 9].contains(end - index) {
                        add("HEX", slice(index, end), startLine, startCol, end)
                        col += end - index; index = end; continue
                    }
                }

                if ch == 40 && unit(index + 1) == 41 {
                    var end = index + 2
                    while end < count && (unit(end) == 32 || unit(end) == 9) { end += 1 }
                    if unit(end) == 61 && unit(end + 1) == 62 {
                        end += 2
                        while end < count && (unit(end) == 32 || unit(end) == 9) { end += 1 }
                        let expressionStart = end
                        var depth = 0
                        while end < count {
                            let value = unit(end)
                            if value == 40 { depth += 1 }
                            else if value == 41 {
                                if depth == 0 { break }
                                depth -= 1
                            } else if depth == 0 && (value == 44 || value == 59 || value == 10 || value == 125) {
                                break
                            }
                            end += 1
                        }
                        var trimmedStart = expressionStart
                        var trimmedEnd = end
                        while trimmedStart < trimmedEnd && isJSTrimSpace(unit(trimmedStart)) { trimmedStart += 1 }
                        while trimmedEnd > trimmedStart && isJSTrimSpace(unit(trimmedEnd - 1)) { trimmedEnd -= 1 }
                        add("FUNC", slice(trimmedStart, trimmedEnd), startLine, startCol, end)
                        col += end - index; index = end; continue
                    }
                }

                if ch == 46 && isDigit(unit(index + 1)) {
                    var end = index + 1
                    while end < count && isDigit(unit(end)) { end += 1 }
                    add("NUMBER", slice(index, end), startLine, startCol, end)
                    col += end - index; index = end; continue
                }
                let punctuation: [UInt16: String] = [
                    46: "DOT", 40: "LPAREN", 41: "RPAREN", 123: "LBRACE", 125: "RBRACE",
                    91: "LBRACKET", 93: "RBRACKET", 44: "COMMA", 58: "COLON", 61: "EQUAL",
                    59: "SEMICOLON", 43: "PLUS", 45: "MINUS", 42: "STAR", 47: "SLASH"
                ]
                if let type = punctuation[ch] {
                    add(type, slice(index, index + 1), startLine, startCol, index + 1)
                    index += 1; col += 1; continue
                }

                if ch == 34 && unit(index + 1) == 34 && unit(index + 2) == 34 {
                    var end = index + 3
                    while end < count - 2 {
                        if unit(end) == 34 && unit(end + 1) == 34 && unit(end + 2) == 34 { break }
                        if unit(end) == 10 { line += 1; col = 0 }
                        end += 1
                    }
                    if end >= count - 2 || !(unit(end) == 34 && unit(end + 1) == 34 && unit(end + 2) == 34) {
                        throw fail("L002", "Unterminated triple-quoted string at line \(startLine) col \(startCol)", index, count)
                    }
                    let content = slice(index + 3, end)
                    add("STRING", content, startLine, startCol, end + 3)
                    if let lastNewline = units[(index + 3)..<end].lastIndex(of: 10) {
                        col = end - lastNewline - 1 + 4
                    } else { col += end - index + 3 }
                    index = end + 3; continue
                }

                if ch == 34 || ch == 39 {
                    var end = index + 1
                    while end < count && unit(end) != ch && unit(end) != 10 {
                        if unit(end) == 92 && end + 1 < count { end += 2 }
                        else { end += 1 }
                    }
                    if end >= count || unit(end) == 10 {
                        throw fail("L002", "Unterminated string literal at line \(line) col \(col)", index, end)
                    }
                    add("STRING", slice(index + 1, end), startLine, startCol, end + 1)
                    col += end - index + 1; index = end + 1; continue
                }

                if isDigit(ch) {
                    var end = index
                    while end < count && isDigit(unit(end)) { end += 1 }
                    if unit(end) == 46 && isDigit(unit(end + 1)) {
                        end += 1
                        while end < count && isDigit(unit(end)) { end += 1 }
                    }
                    add("NUMBER", slice(index, end), startLine, startCol, end)
                    col += end - index; index = end; continue
                }

                if isLetter(ch) || ch == 95 {
                    var end = index
                    while end < count && (isLetter(unit(end)) || isDigit(unit(end)) || unit(end) == 95) { end += 1 }
                    let lexeme = slice(index, end)
                    if let inherited = Self.inheritedKeyword(lexeme) {
                        add(inherited.0, lexeme, startLine, startCol, end, jsTypeKind: inherited.1)
                    } else {
                        add(Self.keywords[lexeme] ?? "IDENT", lexeme, startLine, startCol, end)
                    }
                    col += end - index; index = end; continue
                }

                let rawMessage = Array("Unexpected character '".utf16) + [ch]
                    + Array("' at line \(line) col \(col)".utf16)
                throw fail("L001", String(decoding: rawMessage, as: UTF16.self), index, index + 1,
                           messageUTF16: rawMessage)
            }
            add("EOF", "", line, col, count)
            return tokens
        }
    }
}
