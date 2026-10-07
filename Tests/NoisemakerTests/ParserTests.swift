import Foundation
import XCTest
@testable import Noisemaker

final class ParserTests: XCTestCase {
    private struct Lock: Decodable {
        let commit: String
        let sourceManifestSha256: String
    }

    private struct Authority: Decodable {
        let commit: String
        let sourceManifestSha256: String
        let namespaces: [String]
    }

    private struct Corpus: Decodable {
        let authority: Authority
    }

    private func cases() throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"]
            .map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/reference")
        let data = try Data(contentsOf: reference.appendingPathComponent("parser.json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        let lock = try JSONDecoder().decode(Lock.self,
            from: Data(contentsOf: root.appendingPathComponent("parity/reference.json")))
        XCTAssertEqual(corpus.authority.commit, lock.commit)
        XCTAssertEqual(corpus.authority.sourceManifestSha256, lock.sourceManifestSha256)
        XCTAssertEqual(corpus.authority.namespaces, NoisemakerParser.builtInNamespaces)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["cases"] as? [[String: Any]])
    }

    func testASTAndSubchainWarningsMatchLockedUpstreamParser() throws {
        let corpus = try cases()
        var compared = 0
        for item in corpus where item["ast"] != nil {
            let name = try XCTUnwrap(item["name"] as? String)
            let source = try XCTUnwrap(item["source"] as? String)
            let strict = item["strict"] as? Bool ?? false
            let expected = try ParserValue.decodeTagged(try XCTUnwrap(item["ast"]))
            let actual = try parseCase(source, item: item, strict: strict)
            XCTAssertEqual(actual, expected, name)
            let warningData = try JSONSerialization.data(withJSONObject: item["warnings"] as? [Any] ?? [])
            let warnings = try JSONDecoder().decode([ParserDiagnostic].self, from: warningData)
            XCTAssertEqual(actual.collectSubchainArgumentDiagnostics(), warnings, name)
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 18)
    }

    func testErrorsAndUTF16SpansMatchLockedUpstreamParser() throws {
        let corpus = try cases()
        var compared = 0
        for item in corpus where item["error"] != nil {
            let name = try XCTUnwrap(item["name"] as? String)
            let source = try XCTUnwrap(item["source"] as? String)
            let strict = item["strict"] as? Bool ?? false
            let failure = try XCTUnwrap(item["error"] as? [String: Any])
            let diagnostic = try XCTUnwrap(failure["diagnostic"])
            let expected = try JSONDecoder().decode(ParserDiagnostic.self,
                from: JSONSerialization.data(withJSONObject: diagnostic))
            XCTAssertThrowsError(try parseCase(source, item: item, strict: strict), name) { error in
                guard let actual = error as? ParserError else {
                    XCTFail("\(name): expected ParserError, got \(error)")
                    return
                }
                XCTAssertEqual(actual.diagnostic, expected, name)
                XCTAssertEqual(actual.localizedDescription, failure["message"] as? String, name)
            }
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 12)
    }

    private func parseCase(_ source: String, item: [String: Any], strict: Bool) throws -> ParserValue {
        if item["callerTokens"] as? Bool == true {
            let tokens = try NoisemakerLexer.lex(source).map { token in
                LexerToken(type: token.type, lexeme: token.lexeme, line: token.line, col: token.col)
            }
            return try NoisemakerParser.parse(tokens: tokens, strictSubchainArguments: strict)
        }
        return try NoisemakerParser.parse(source, strictSubchainArguments: strict)
    }

    func testIncompleteTokenStreamFailsExplicitly() throws {
        XCTAssertThrowsError(try NoisemakerParser.parse(tokens: [])) { error in
            XCTAssertTrue(error is ParserIncomplete)
        }
        let tokens = try NoisemakerLexer.lex("search synth")
        XCTAssertThrowsError(try NoisemakerParser.parse(tokens: Array(tokens.dropLast()))) { error in
            XCTAssertTrue(error is ParserIncomplete)
        }
        let valid = try NoisemakerLexer.lex("search synth")
        XCTAssertThrowsError(try NoisemakerParser.parse(tokens: valid + valid)) { error in
            XCTAssertTrue(error is ParserIncomplete)
        }
    }

    func testMalformedCallerNumericTokensFailWithoutTrapping() throws {
        let tokens = try NoisemakerLexer.lex("search synth\nlet x = 1")
        let index = try XCTUnwrap(tokens.firstIndex(where: { $0.type == "NUMBER" }))
        _ = try NoisemakerParser.parse(tokens: tokens)
        let original = tokens[index]
        for (type, lexeme) in [
            ("NUMBER", "not-a-number"), ("NUMBER", "1e3"), ("NUMBER", "1.2.3"),
            ("HEX", "#"), ("HEX", "#ggg"), ("HEX", "#abcd"), ("HEX", "#123456789")
        ] {
            var malformed = tokens
            malformed[index] = LexerToken(type: type, lexeme: lexeme, line: original.line,
                                          col: original.col, position: original.position)
            XCTAssertThrowsError(try NoisemakerParser.parse(tokens: malformed), "\(type) \(lexeme)") { error in
                XCTAssertTrue(error is ParserIncomplete, "\(type) \(lexeme): \(error)")
            }
        }
    }
}
