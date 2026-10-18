import Foundation
import Testing
@testable import Noisemaker

struct ErrorDescriptionTests {
    @Test func publicErrorsDescribeThemselvesToHosts() throws {
        let unknownEffect = CompilationError(diagnostics: [
            CompilerDiagnostic(code: "S001", severity: "error", message: "Unknown effect: 'noiz'", location: nil),
            CompilerDiagnostic(code: "S005", severity: "error",
                               message: "write() requires an input - cannot be first in chain: '[Write]'",
                               location: Noisemaker.SourceLocation(line: 2, column: 15))
        ])
        let errors: [(any Error, String)] = [
            (GraphDiagnostic.invalid("render size"), "Invalid exported graph: render size"),
            (GraphDiagnostic.unsupported("write3d"), "Unsupported graph semantics: write3d"),
            (GraphDiagnostic.missing("external textures [\"node_1_overlayTex\"]"),
             "Missing graph resource: external textures [\"node_1_overlayTex\"]"),
            (CatalogError.malformed("effects"), "Malformed catalog: effects"),
            (CatalogError.missingResource, "Bundled catalog resource is missing"),
            (RenderSubmissionError.capacityExceeded, "All three frame submission slots are in flight"),
            (RenderSubmissionError.uncommittedFrame, "Commit or discard the previous frame before encoding another"),
            (RenderSubmissionError.differentCommandQueue,
             "A renderer must use one command queue for ordered GPU execution"),
            (TintTranslationError.invalidInput("entry point"), "Invalid shader translation input: entry point"),
            (TintTranslationError.translationFailed("parse"), "Shader translation failed: parse"),
            (UniformError.invalidLayout("offset"), "Invalid uniform layout: offset"),
            (UniformError.invalidValue("scale"), "Invalid uniform value: scale"),
            (CompilerIncomplete(stage: "expander", detail: "pass"), "Native expander incomplete: pass"),
            (ParserIncomplete("branch"), "Native parser incomplete: branch"),
            (unknownEffect, "S001 error: Unknown effect: 'noiz'; "
                + "S005 error at line 2 col 15: write() requires an input - cannot be first in chain: '[Write]'")
        ]
        for (error, text) in errors {
            #expect(error.localizedDescription == text)
            #expect(String(describing: error) == text)
        }
    }

    @Test func lexerAndParserErrorsCarryCodeAndLocation() throws {
        expectThrows(try NoisemakerParser.parse("search synth\nnoise(seed: 1.write(o0)\nrender(o0)\n")) { error in
            guard let parser = error as? ParserError else { return recordFailure("expected ParserError, got \(error)") }
            #expect(parser.diagnostic.code == "P002")
            #expect(error.localizedDescription == "P002 error: \(parser.diagnostic.message)")
            #expect(error.localizedDescription.hasSuffix("at line 2 col 14"))
            #expect(String(describing: error) == error.localizedDescription)
        }
        expectThrows(try NoisemakerLexer.lex("search synth\nnoise(seed: $)\n")) { error in
            guard let lexer = error as? LexerError else { return recordFailure("expected LexerError, got \(error)") }
            #expect(error.localizedDescription ==
                "\(lexer.diagnostic.code) \(lexer.diagnostic.severity): \(lexer.diagnostic.message)")
            #expect(lexer.diagnostic.message.contains("line 2"))
            #expect(String(describing: error) == error.localizedDescription)
        }
    }
}
