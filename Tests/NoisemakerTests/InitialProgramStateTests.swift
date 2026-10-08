import CryptoKit
import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct InitialProgramStateTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func json(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(relative))
        return try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value,
                                               options: [.sortedKeys, .fragmentsAllowed])
        return try requireValue(String(data: data, encoding: .utf8))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func sourceInitialControlsKeepCompilerStagesRawAndMatchHostPasses() throws {
        let oracle = try json("parity/initial-program-state.json")
        let corpus = try json("parity/corpus.json")
        let stages = try json("parity/corpus-stages.json")
        let authority = try json("parity/reference.json")
        let corpusData = try Data(contentsOf: root.appendingPathComponent("parity/corpus.json"))
        expectEqual(try canonical(requireValue(oracle["authority"])),
                    try canonical(authority), "source authority")
        expectEqual(oracle["corpusSha256"] as? String, digest(corpusData), "corpus bytes")
        expectEqual(stages["corpusSha256"] as? String, digest(corpusData), "stage corpus bytes")
        let references = try requireValue(oracle["cases"] as? [[String: Any]])
        let cases = try requireValue(corpus["cases"] as? [[String: Any]])
        let stageCases = try requireValue(stages["cases"] as? [[String: Any]])
        let registry = try EffectRegistry.bundled()
        let compiler = NoisemakerCompiler(registry: registry)
        for reference in references {
            let id = try requireValue(reference["id"] as? String)
            let source = try requireValue(cases.first(where: { ($0["id"] as? String) == id })?["source"] as? String)
            expectEqual(reference["sourceSha256"] as? String, digest(Data(source.utf8)),
                        "\(id): source bytes")
            let stageRecord = stageCases.first(where: { ($0["id"] as? String) == id })
            let graphStage = stageRecord?["stages"] as? [String: [String: Any]]
            expectEqual(reference["graphStageSha256"] as? String,
                        graphStage?["graph"]?["sha256"] as? String,
                        "\(id): graph stage oracle")
            let stage = try compiler.compileStages(source: source)
            let rawBefore = try canonical(stage.graph.taggedValue())
            var graph = try compiler.compileForHost(source: source)
            let limit = try requireValue(reference["maxTextureDimension2D"] as? Int)
            graph = try graph.clampingVolumeSizes(maximumTextureDimension2D: limit,
                                                  registry: registry)
            expectEqual(try canonical(stage.graph.taggedValue()), rawBefore, "\(id): stage mutation")
            let expected = try requireValue(reference["passes"] as? [[String: Any]])
            expectEqual(graph.passes.count, expected.count, "\(id): pass count")
            for (pass, item) in zip(graph.passes, expected) {
                expectEqual(pass.id, item["id"] as? String, "\(id): pass id")
                expectEqual(try canonical(pass.raw.field("uniforms")?.taggedValue() ?? [:]),
                            try canonical(requireValue(item["uniforms"])), "\(id): \(pass.id) uniforms")
            }
            if id.hasPrefix("coverage/points_") {
                let textures = try requireValue(reference["textures"] as? [[String: Any]])
                let sourceXyz = try requireValue(textures.first(where: {
                    ($0["id"] as? String) == "global_xyz_node_1_read"
                }))
                let nativeXyz = try requireValue(graph.textures.first(where: {
                    $0.key == "global_xyz_node_1"
                }))
                let width = try nativeXyz.width.resolve(screen: 256,
                                                        parameters: graph.dimensionParameters)
                let height = try nativeXyz.height.resolve(screen: 256,
                                                          parameters: graph.dimensionParameters)
                expectEqual(width, sourceXyz["width"] as? Int, "\(id): physical xyz width")
                expectEqual(height, sourceXyz["height"] as? Int, "\(id): physical xyz height")
            }
        }
    }

    @Test func paletteNoneKeepsRawDependentUniformsForSevenSourceCases() throws {
        let corpus = try json("parity/corpus.json")
        let cases = try requireValue(corpus["cases"] as? [[String: Any]])
        let selected = cases.filter {
            ($0["id"] as? String)?.hasPrefix("coverage/classicNoisedeck_") == true &&
                ($0["id"] as? String)?.hasSuffix("__palette_none") == true
        }
        expectEqual(selected.count, 7)
        let registry = try EffectRegistry.bundled()
        let compiler = NoisemakerCompiler(registry: registry)
        let dependent = ["paletteOffset", "paletteAmp", "paletteFreq",
                         "palettePhase", "paletteMode"]
        for item in selected {
            let id = try requireValue(item["id"] as? String)
            let source = try requireValue(item["source"] as? String)
            let raw = try compiler.compile(source: source)
            let host = try compiler.compileForHost(source: source)
            var checked = 0
            for original in raw.passes {
                guard original.raw.field("uniforms")?.field("palette")?.numberValue == 0 else {
                    continue
                }
                let actual = try requireValue(host.passes.first { $0.id == original.id },
                                              "\(id): matching host pass")
                expectEqual(actual.raw.field("uniforms")?.field("palette")?.numberValue,
                            0, "\(id): palette none stays zero")
                for name in dependent {
                    let before = original.raw.field("uniforms")?.field(name)
                    let after = actual.raw.field("uniforms")?.field(name)
                    expectEqual(try canonical(before?.taggedValue() ?? ["$type": "undefined"]),
                                try canonical(after?.taggedValue() ?? ["$type": "undefined"]),
                                "\(id): \(name) remains unexpanded")
                }
                checked += 1
            }
            expectTrue(checked > 0, "\(id) contains no palette-none pass")
        }
    }
}
