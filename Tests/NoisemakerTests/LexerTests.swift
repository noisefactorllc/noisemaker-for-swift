import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct LexerTests {
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
        expectEqual(corpus.authority.commit, lock.commit)
        expectEqual(corpus.authority.sourceManifestSha256, lock.sourceManifestSha256)
        expectEqual(corpus.authority.lexerSha256.count, 64)
        expectEqual(corpus.authority.compilerSha256.count, 64)
        return corpus
    }

    @Test func testTokensAndUTF16PositionsMatchLockedUpstreamLexer() throws {
        let corpus = try corpus()
        var compared = 0
        for item in corpus.cases {
            guard let expected = item.tokens else { continue }
            expectNil(item.error, item.name)
            let actual = try NoisemakerLexer.lex(item.source)
            expectEqual(actual, expected, item.name)
            compared += 1
        }
        expectAtLeast(compared, 12)
    }

    @Test func testFailuresMatchLockedUpstreamDiagnostics() throws {
        let corpus = try corpus()
        var compared = 0
        for item in corpus.cases {
            guard let expected = item.error else { continue }
            expectNil(item.tokens, item.name)
            expectThrows(try NoisemakerLexer.lex(item.source), item.name) { error in
                guard let actual = error as? LexerError else {
                    recordFailure("\(item.name): expected LexerError, got \(error)")
                    return
                }
                expectEqual(actual.diagnostic, expected.diagnostic, item.name)
                expectEqual(actual.localizedDescription, expected.message, item.name)
            }
            compared += 1
        }
        expectAtLeast(compared, 10)
    }

    @Test func testSigned32Base36SourceHashesMatchLockedUpstream() throws {
        let corpus = try corpus()
        expectAtLeast(corpus.cases.count, 20)
        for item in corpus.cases {
            expectEqual(NoisemakerLexer.hashSource(item.source), item.hash, item.name)
        }
    }
}
