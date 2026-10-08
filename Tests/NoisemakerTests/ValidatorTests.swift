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
        let portableCases: Set<String> = ["marker", "mrtProbe", "samplerProbe", "sampled3dProbe"]
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
                #expect(throws: CompilerIncomplete.self) {
                    try NoisemakerValidator.validate(parsed, registry: registry)
                }
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
}
