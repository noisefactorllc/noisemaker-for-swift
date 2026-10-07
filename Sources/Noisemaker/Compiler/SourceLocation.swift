import Foundation

public struct SourceSpan: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct SourceLocation: Codable, Equatable, Sendable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public struct SourcePosition: Codable, Equatable, Sendable {
    public let line: Int
    public let column: Int
    public let start: Int
    public let end: Int

    public init(line: Int, column: Int, start: Int, end: Int) {
        self.line = line
        self.column = column
        self.start = start
        self.end = end
    }
}

public struct LexerDiagnostic: Codable, Equatable, Sendable {
    public let code: String
    public let stage: String
    public let severity: String
    public let message: String
    /// Preserves JavaScript's exact UTF-16 message, including lone surrogates.
    public let messageUTF16: [UInt16]
    public let location: SourceLocation
    public let span: SourceSpan
}

public struct LexerError: Error, Equatable, Sendable, LocalizedError {
    public let diagnostic: LexerDiagnostic

    public var errorDescription: String? { diagnostic.message }

    public init(diagnostic: LexerDiagnostic) {
        self.diagnostic = diagnostic
    }
}

public struct LexerToken: Codable, Equatable, Sendable {
    public let type: String
    public let lexeme: String
    public let line: Int
    public let col: Int
    public let position: SourcePosition?
    /// Set when the upstream keyword lookup returns an inherited non-string JS value.
    /// `type` then holds that value's string coercion for parser diagnostics.
    public let jsTypeKind: String?

    public init(type: String, lexeme: String, line: Int, col: Int,
                position: SourcePosition? = nil, jsTypeKind: String? = nil) {
        self.type = type
        self.lexeme = lexeme
        self.line = line
        self.col = col
        self.position = position
        self.jsTypeKind = jsTypeKind
    }
}
