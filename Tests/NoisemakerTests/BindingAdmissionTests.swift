import CryptoKit
import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized) struct BindingAdmissionTests {
    @Test func pinnedWebGPUSpacingSyntax() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let oracle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("parity/binding-oracle.json"))) as? [String: Any])
        let cases = try #require(oracle["syntaxCases"] as? [[String: Any]])
        #expect(cases.count == 2)
        for item in cases {
            let wgsl = try #require(item["wgsl"] as? String)
            let digest = SHA256.hash(data: Data(wgsl.utf8))
                .map { String(format: "%02x", $0) }.joined()
            #expect(digest == item["wgslSha256"] as? String)
            let actual = try ShaderCompiler.bindingDeclarations(wgsl)
            let expected = try #require(item["bindings"] as? [[String: Any]])
            #expect(actual.count == expected.count)
            for (found, wanted) in zip(actual, expected) {
                #expect(Int(found.group) == wanted["group"] as? Int)
                #expect(Int(found.binding) == wanted["binding"] as? Int)
                #expect(found.name == wanted["name"] as? String)
                #expect(found.addressSpace == wanted["storage"] as? String)
                #expect(found.type == wanted["typeDecl"] as? String)
            }
        }
    }

    @Test func pinnedWebGPUBindingInventory() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = try Data(contentsOf: root.appendingPathComponent("parity/binding-oracle.json"))
        let oracle = try #require(JSONSerialization.jsonObject(with: file) as? [String: Any])
        let cases = try #require(oracle["cases"] as? [[String: Any]])
        let corpus = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("parity/corpus.json"))) as? [String: Any])
        let records = try #require(corpus["cases"] as? [[String: Any]])
        let sources = Dictionary(uniqueKeysWithValues: records.compactMap { row -> (String, String)? in
            guard let id = row["id"] as? String, let source = row["source"] as? String else { return nil }
            return (id, source)
        })
        let compiler = try NoisemakerCompiler()
        var failures: [String] = []
        var examined = 0
        for item in cases {
            let id = try #require(item["id"] as? String)
            let source = try #require(sources[id])
            let graph = try compiler.compile(source: source)
            let passes = try #require(item["passes"] as? [[String: Any]])
            for expected in passes {
                let passID = try #require(expected["passId"] as? String)
                let pass = try #require(graph.passes.first { $0.id == passID })
                let program = try #require(graph.programs[pass.program])
                let sha = SHA256.hash(data: Data(program.resolvedWGSL.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                if sha != expected["resolvedWgslSha256"] as? String {
                    failures.append("\(id)/\(passID): source hash")
                    continue
                }
                let actual = try ShaderCompiler.bindingDeclarations(program.resolvedWGSL)
                let bindings = try #require(expected["bindings"] as? [[String: Any]])
                let shape = bindings.compactMap { row -> String? in
                    guard let group = row["group"] as? Int,
                          let binding = row["binding"] as? Int,
                          let storage = row["storage"] as? String,
                          let name = row["name"] as? String,
                          let type = row["typeDecl"] as? String else { return nil }
                    return "\(group)/\(binding)/\(storage)/\(name)/\(type)"
                }
                let candidate = actual.map {
                    "\($0.group)/\($0.binding)/\($0.addressSpace)/\($0.name)/\($0.type)"
                }
                if candidate != shape { failures.append("\(id)/\(passID): \(candidate) != \(shape)") }
                examined += 1
            }
        }
        #expect(cases.count == 13)
        #expect(examined == 41)
        #expect(failures.isEmpty, "\(failures.prefix(8))")
    }

    @Test func deadBindingsIgnoreNestedCommentsAndWholeWords() throws {
        let source = """
            @group(0) @binding(0) var unused: texture_2d<f32>;
            @group(0) @binding(1) var live: texture_2d<f32>;
            @group(0) @binding(2) var<storage, read_write> output_buffer: array<f32>;
            /* unused /* unused */ unused */
            // unused
            fn main() { let longer = live; }
            """
        let names = try ShaderCompiler.bindingDeclarations(source).map(\.name)
        #expect(names == ["live", "output_buffer"])
    }
}
