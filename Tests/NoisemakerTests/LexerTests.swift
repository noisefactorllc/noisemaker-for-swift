import Foundation
import XCTest
@testable import Noisemaker

final class LexerTests: XCTestCase {
    private struct Authority: Decodable {
        let commit: String
        let sourceManifestSha256: String
        let lexerSha256: String
        let compilerSha256: String
    }

    private struct Failure: Decodable {
        let message: String
        let diagnostic: LexerDiagnostic
    }

    private struct Case: Decodable {
        let name: String
        let source: String
        let hash: String
        let tokens: [LexerToken]?
        let error: Failure?
    }

    private struct Corpus: Decodable {
        let authority: Authority
        let cases: [Case]
    }

    private struct Lock: Decodable {
        let commit: String
        let sourceManifestSha256: String
    }

    private func corpus() throws -> Corpus {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let lock = try JSONDecoder().decode(Lock.self,
            from: Data(contentsOf: root.appendingPathComponent("parity/reference.json")))
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"]
            .map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/reference")
        let corpus = try JSONDecoder().decode(Corpus.self,
            from: Data(contentsOf: reference.appendingPathComponent("lexer.json")))
        XCTAssertEqual(corpus.authority.commit, lock.commit)
        XCTAssertEqual(corpus.authority.sourceManifestSha256, lock.sourceManifestSha256)
        XCTAssertEqual(corpus.authority.lexerSha256.count, 64)
        XCTAssertEqual(corpus.authority.compilerSha256.count, 64)
        return corpus
    }

    func testTokensAndUTF16PositionsMatchLockedUpstreamLexer() throws {
        let corpus = try corpus()
        var compared = 0
        for item in corpus.cases {
            guard let expected = item.tokens else { continue }
            XCTAssertNil(item.error, item.name)
            let actual = try NoisemakerLexer.lex(item.source)
            XCTAssertEqual(actual, expected, item.name)
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 12)
    }

    func testFailuresMatchLockedUpstreamDiagnostics() throws {
        let corpus = try corpus()
        var compared = 0
        for item in corpus.cases {
            guard let expected = item.error else { continue }
            XCTAssertNil(item.tokens, item.name)
            XCTAssertThrowsError(try NoisemakerLexer.lex(item.source), item.name) { error in
                guard let actual = error as? LexerError else {
                    XCTFail("\(item.name): expected LexerError, got \(error)")
                    return
                }
                XCTAssertEqual(actual.diagnostic, expected.diagnostic, item.name)
                XCTAssertEqual(actual.localizedDescription, expected.message, item.name)
            }
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 10)
    }

    func testSigned32Base36SourceHashesMatchLockedUpstream() throws {
        let corpus = try corpus()
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 20)
        for item in corpus.cases {
            XCTAssertEqual(NoisemakerLexer.hashSource(item.source), item.hash, item.name)
        }
    }
}
