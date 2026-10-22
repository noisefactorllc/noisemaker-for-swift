import CryptoKit
import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized) struct ValidatorTests {
    @Test func lockedCatalogValidationStages() throws {
        let registry = try EffectRegistry.bundled()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"]
            .map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/reference")
        let directory = reference.appendingPathComponent("cases")
        // Only the source export's declared inventory is authoritative. Other
        // diagnostic probes may coexist in the generated output directory.
        let summary = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            reference.appendingPathComponent("summary.json"))) as? [String: Any])
        let inventory = try #require(summary["cases"] as? [String: [String: Any]])
        let files = inventory.keys.sorted().map { directory.appendingPathComponent($0 + ".json") }
        let portableCases: Set<String> = ["marker", "mrtProbe", "samplerProbe", "sampled3dProbe",
                                          "sampled3dLinearProbe", "storage3dProbe"]
        var compared = 0
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let caseFile = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let stages = try #require(caseFile["stages"] as? [String: Any])
            let source = try #require(stages["source"] as? String)
            let sourceSHA = SHA256.hash(data: Data(source.utf8))
                .map { String(format: "%02x", $0) }.joined()
            #expect(sourceSHA == inventory[name]?["sourceSha256"] as? String)
            let parsed = try NoisemakerParser.parse(source)
            if portableCases.contains(name) {
                // The bundled registry lacks these Portable effects, so upstream
                // reports each one as an unknown effect.
                let validated = try NoisemakerValidator.validate(parsed, registry: registry)
                #expect(throws: CompilationError.self) { try CompilationError.check(validated) }
                continue
            }
            let actual = try NoisemakerValidator.validate(parsed, registry: registry)
            let expected = try ParserValue.decodeTagged(#require(stages["validate"]))
            #expect(actual == expected, "\(name) validator stage")
            compared += 1
        }
        #expect(compared == files.count - portableCases.count)
        #expect(compared >= 9)
    }

    @Test func invalidProgramsReportLockedDiagnostics() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let oracle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("parity/invalid-programs.json"))) as? [String: Any])
        let cases = try #require(oracle["cases"] as? [[String: Any]])
        #expect(cases.count >= 23)
        let compiler = try NoisemakerCompiler()
        for item in cases {
            let id = try #require(item["id"] as? String)
            let source = try #require(item["source"] as? String)
            let expected = try #require(item["diagnostics"] as? [[String: Any]]).map { entry in
                let location = (entry["location"] as? [String: Any]).flatMap { location -> Noisemaker.SourceLocation? in
                    guard let line = location["line"] as? Int, let column = location["column"] as? Int else { return nil }
                    return Noisemaker.SourceLocation(line: line, column: column)
                }
                return CompilerDiagnostic(code: entry["code"] as? String ?? "",
                                          severity: entry["severity"] as? String ?? "",
                                          message: entry["message"] as? String ?? "", location: location)
            }
            do {
                _ = try compiler.compile(source: source)
                Issue.record("\(id) compiled")
            } catch let error as CompilationError {
                #expect(error.diagnostics == expected, "\(id)")
            } catch {
                Issue.record("\(id): expected CompilationError, got \(error)")
            }
        }
        let accepted = try #require(oracle["accepted"] as? [[String: Any]])
        #expect(accepted.count >= 4)
        for item in accepted {
            let id = try #require(item["id"] as? String)
            do {
                _ = try compiler.compile(source: try #require(item["source"] as? String))
            } catch let error as CompilationError {
                Issue.record("\(id): the locked compiler accepts this program, but Swift reported \(error)")
            } catch {
                #expect(error is CompilerIncomplete, "\(id): \(error)")
            }
        }
    }

    @Test func controlFlowProgramsFailExpansionAsLockedUpstream() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let oracle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("parity/invalid-programs.json"))) as? [String: Any])
        let cases = try #require(oracle["expansionFailures"] as? [[String: Any]])
        #expect(cases.count >= 2)
        let compiler = try NoisemakerCompiler()
        for item in cases {
            let id = try #require(item["id"] as? String)
            let source = try #require(item["source"] as? String)
            let errors = try #require(item["errors"] as? [String])
            do {
                _ = try compiler.compile(source: source)
                Issue.record("\(id) compiled")
            } catch let error as ExpansionError {
                #expect(error.messages == errors, "\(id)")
            } catch {
                Issue.record("\(id): expected ExpansionError, got \(error)")
            }
        }
    }

    @Test func acceptedProgramsReportLockedWarnings() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let oracle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("parity/invalid-programs.json"))) as? [String: Any])
        let cases = try #require(oracle["warnings"] as? [[String: Any]])
        #expect(cases.count >= 1)
        let compiler = try NoisemakerCompiler()
        for item in cases {
            let id = try #require(item["id"] as? String)
            let source = try #require(item["source"] as? String)
            let expected = try #require(item["diagnostics"] as? [[String: Any]]).map { entry in
                let location = (entry["location"] as? [String: Any]).flatMap { location -> Noisemaker.SourceLocation? in
                    guard let line = location["line"] as? Int, let column = location["column"] as? Int else { return nil }
                    return Noisemaker.SourceLocation(line: line, column: column)
                }
                return CompilerDiagnostic(code: entry["code"] as? String ?? "",
                                          severity: entry["severity"] as? String ?? "",
                                          message: entry["message"] as? String ?? "", location: location)
            }
            let stages = try compiler.compileStages(source: source)
            let actual = (stages.validated.field("diagnostics")?.elements ?? []).map { entry in
                let location = entry.field("location").flatMap { location -> Noisemaker.SourceLocation? in
                    guard let line = location.field("line")?.number,
                          let column = location.field("column")?.number else { return nil }
                    return Noisemaker.SourceLocation(line: Int(line), column: Int(column))
                }
                return CompilerDiagnostic(code: entry.field("code")?.string ?? "",
                                          severity: entry.field("severity")?.string ?? "",
                                          message: entry.field("message")?.string ?? "", location: location)
            }
            #expect(actual == expected, "\(id)")
        }
    }
}
