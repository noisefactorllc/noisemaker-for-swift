import CoreFoundation
import CryptoKit
import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized) struct CorpusStageParityTests {
    @Test func sampled3dTextureSpecKeepsLockedFieldOrderAndTruthyFilter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let corpus = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("parity/corpus.json"))) as? [String: Any])
        let records = try #require(corpus["cases"] as? [[String: Any]])
        let record = try #require(records.first { $0["id"] as? String == "micro/sampled3dProbe" })
        let source = try #require(record["source"] as? String)
        let assets = try #require(record["assets"] as? [[String: Any]])
        let definition = try #require(assets.first {
            ($0["path"] as? String)?.hasSuffix(".portable.json") == true
        }?["text"] as? String)
        let shader = try #require(assets.first {
            ($0["path"] as? String)?.hasSuffix(".show.wgsl") == true
        }?["text"] as? String)

        func textureFields(_ definition: String) throws -> [String] {
            var registry = try EffectRegistry.bundled()
            try registry.registerPortable(definitionJSON: Data(definition.utf8),
                                          orderedShaderSources: [("show", shader)])
            let graph = try NoisemakerCompiler(registry: registry)
                .compileStages(source: source).graph
            let texture = try #require(graph.field("textures")?.mapEntries?.first {
                $0.key.stringValue == "node_0_volume"
            }?.value)
            return try #require(texture.objectFields).map(\.name)
        }

        #expect(try textureFields(definition) ==
            ["width", "height", "format", "usage", "depth", "is3D", "filter"])
        let emptyFilter = definition.replacingOccurrences(of: "\"filter\": \"nearest\"",
                                                           with: "\"filter\": \"\"")
        #expect(emptyFilter != definition)
        #expect(try textureFields(emptyFilter) ==
            ["width", "height", "format", "usage", "depth", "is3D"])
    }

    @Test func lockedSourceStagesMatchAllCorpusPrograms() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let corpusData = try Data(contentsOf: root.appendingPathComponent("parity/corpus.json"))
        let corpus = try #require(JSONSerialization.jsonObject(with: corpusData) as? [String: Any])
        let records = try #require(corpus["cases"] as? [[String: Any]])
        let stages = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("parity/corpus-stages.json"))) as? [String: Any])
        let expected = try #require(stages["cases"] as? [[String: Any]])
        let identity = try #require(stages["authority"] as? [String: Any])
        var registry = try EffectRegistry.bundled()
        #expect(identity["commit"] as? String == registry.authorityCommit)
        #expect(identity["sourceManifestSha256"] as? String == registry.sourceManifestSha256)
        #expect(stages["corpusSha256"] as? String == sha(corpusData))
        #expect(!records.isEmpty)
        let familyCounts = try #require(corpus["expected"] as? [String: Int])
        let actualFamilyCounts = try Dictionary(grouping: records) { record in
            try #require(record["family"] as? String)
        }.mapValues(\.count)
        #expect(actualFamilyCounts == familyCounts)
        #expect(records.count == familyCounts.values.reduce(0, +))
        #expect(records.count == stages["expected"] as? Int)
        #expect(records.count == expected.count)

        for record in records {
            let assets = try #require(record["assets"] as? [[String: Any]])
            guard let definition = assets.first(where: {
                ($0["path"] as? String)?.hasSuffix(".portable.json") == true
            }) else { continue }
            let definitionText = try #require(definition["text"] as? String)
            let shaders = try assets.filter {
                ($0["path"] as? String)?.hasSuffix(".wgsl") == true
            }.map { asset -> (String, String) in
                let path = try #require(asset["path"] as? String)
                let source = try #require(asset["text"] as? String)
                let parts = path.split(separator: "/").last!.split(separator: ".")
                return (String(parts[parts.count - 2]), source)
            }
            try registry.registerPortable(definitionJSON: Data(definitionText.utf8),
                                          orderedShaderSources: shaders)
        }
        let compiler = NoisemakerCompiler(registry: registry)
        let byID = Dictionary(uniqueKeysWithValues: expected.compactMap { row -> (String, [String: Any])? in
            guard let id = row["id"] as? String else { return nil }
            return (id, row)
        })
        var failures: [String] = []
        for record in records {
            guard let id = record["id"] as? String,
                  let source = record["source"] as? String,
                  let oracle = byID[id],
                  let hashes = oracle["stages"] as? [String: [String: Any]] else {
                failures.append("malformed corpus or missing stage record")
                continue
            }
            if sha(Data(source.utf8)) != oracle["sourceSha256"] as? String {
                failures.append("\(id): source identity")
                continue
            }
            do {
                let compiled = try compiler.compileStages(source: source)
                let lexical = try NoisemakerLexer.lex(source)
                let values: [(String, Any)] = [
                    ("lex", lexical.map(tokenView)),
                    ("parse", compiled.parsed.taggedValue()),
                    ("validate", compiled.validated.taggedValue()),
                    ("expand", compiled.expanded.taggedValue()),
                    ("allocate", compiled.allocations.taggedValue()),
                    ("graph", compiled.graph.taggedValue())
                ]
                for (stage, value) in values {
                    if sha(Data(canonical(value).utf8)) != hashes[stage]?["sha256"] as? String {
                        failures.append("\(id): \(stage)")
                    }
                }
            } catch {
                failures.append("\(id): \(error)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(records.count) compiler cases differed: \(failures.prefix(20))")
    }

    private func tokenView(_ token: LexerToken) -> Any {
        let position: Any
        if let value = token.position {
            position = ["$type": "object", "entries": [
                ["line", value.line], ["column", value.column],
                ["start", value.start], ["end", value.end]
            ] as [[Any]]]
        } else {
            position = ["$type": "undefined"]
        }
        return ["$type": "object", "entries": [
            ["type", token.type], ["lexeme", token.lexeme],
            ["line", token.line], ["col", token.col], ["position", position]
        ] as [[Any]]]
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0..<32: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private func jsNumber(_ number: Double) -> String {
        if number == 0 { return "0" }
        let raw = String(number)
        let parts = raw.split(separator: "e", omittingEmptySubsequences: false)
        if parts.count == 1 { return raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw }
        let exponent = Int(parts[1])!
        let sign = raw.hasPrefix("-") ? "-" : ""
        let significand = String(parts[0]).replacingOccurrences(of: "-", with: "")
        let digits = significand.replacingOccurrences(of: ".", with: "")
        let before = significand.split(separator: ".").first!.count
        let decimalPoint = before + exponent
        let absolute = abs(number)
        if absolute >= 1e-6 && absolute < 1e21 {
            if decimalPoint <= 0 { return sign + "0." + String(repeating: "0", count: -decimalPoint) + digits }
            if decimalPoint >= digits.count { return sign + digits + String(repeating: "0", count: decimalPoint - digits.count) }
            let cut = digits.index(digits.startIndex, offsetBy: decimalPoint)
            return sign + digits[..<cut] + "." + digits[cut...]
        }
        let mantissa = String(parts[0]).hasSuffix(".0") ? String(parts[0].dropLast(2)) : String(parts[0])
        return mantissa + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
    }

    private func canonical(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let value = value as? NSNumber {
            return CFGetTypeID(value) == CFBooleanGetTypeID() ? (value.boolValue ? "true" : "false") : jsNumber(value.doubleValue)
        }
        if let value = value as? String { return quote(value) }
        if let values = value as? [Any] { return "[" + values.map(canonical).joined(separator: ",") + "]" }
        guard let object = value as? [String: Any] else { return "null" }
        if let tag = object["$type"] as? String {
            if tag == "object" || tag == "map" {
                return "{\"$type\":" + quote(tag) + ",\"entries\":" + canonical(object["entries"]!) + "}"
            }
            if tag == "number" {
                return "{\"$type\":\"number\",\"value\":" + canonical(object["value"]!) + "}"
            }
            if tag == "function" {
                return "{\"$type\":\"function\",\"source\":" + canonical(object["source"]!) + "}"
            }
            return "{\"$type\":" + quote(tag) + "}"
        }
        return "{" + object.keys.sorted().map { quote($0) + ":" + canonical(object[$0]!) }.joined(separator: ",") + "}"
    }
}
