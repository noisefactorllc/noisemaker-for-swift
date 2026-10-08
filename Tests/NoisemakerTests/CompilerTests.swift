import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized) struct CompilerTests {
    @Test func bundledCatalogCopiesIsolatePortableRegistration() throws {
        var first = try EffectRegistry.bundled()
        let second = try EffectRegistry.bundled()
        let count = first.effects.count
        let definition = #"{"namespace":"user","func":"isolationProbe","passes":[{"program":"probe"}]}"#
        try first.registerPortable(definitionJSON: Data(definition.utf8),
                                   shaderSources: ["probe": "@fragment fn main() {}"])
        #expect(first.effects.count == count + 1)
        #expect(first.effect(key: "user.isolationProbe") != nil)
        #expect(second.effects.count == count)
        #expect(second.effect(key: "user.isolationProbe") == nil)
        #expect(try EffectRegistry.bundled().effect(key: "user.isolationProbe") == nil)
    }

    @Test func rejectedPortableRegistrationLeavesRegistryUsable() throws {
        var registry = try EffectRegistry.bundled()
        let count = registry.effects.count
        let starters = registry.starterOps.count
        let aliases = registry.paramAliases
        let invalid = #"{"namespace":"user","func":"rejectedProbe","globals":{"gain":{"type":"float","default":1}},"paramAliases":{"old":"missing"},"passes":[{"program":"probe"}]}"#
        let shader = ["probe": "@fragment fn main() {}"]
        expectThrows(try registry.registerPortable(definitionJSON: Data(invalid.utf8),
                                                   shaderSources: shader)) { error in
            #expect(error is CatalogError)
        }
        #expect(registry.effects.count == count)
        #expect(registry.starterOps.count == starters)
        #expect(registry.paramAliases.sameOrderedValue(as: aliases))
        #expect(registry.effect(key: "user.rejectedProbe") == nil)
        #expect(registry.validatorOp("user.rejectedProbe") == nil)
        let valid = #"{"namespace":"user","func":"rejectedProbe","passes":[{"program":"probe"}]}"#
        try registry.registerPortable(definitionJSON: Data(valid.utf8), shaderSources: shader)
        #expect(registry.effects.count == count + 1)
        #expect(registry.effect(key: "user.rejectedProbe") != nil)
    }

    @Test func oversizedLogicalStepIndexThrowsWithoutTrapping() throws {
        let step = ParserValue.object([
            ("op", .string("_read")), ("args", .object([])),
            ("temp", .number(Double.greatestFiniteMagnitude)), ("builtin", .bool(true))
        ])
        let plan = ParserValue.object([("chain", .array([step]))])
        let validated = ParserValue.object([
            ("plans", .array([plan])), ("render", .string("o0"))
        ])
        expectThrows(try NoisemakerExpander.expand(validated, registry: EffectRegistry.bundled())) { error in
            #expect(error is CompilerIncomplete)
        }
    }

    @Test func nativeStagesMatchLockedCatalogGraphs() throws {
        var registry = try EffectRegistry.bundled()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let corpus = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("parity/corpus.json"))) as? [String: Any])
        let corpusCases = try #require(corpus["cases"] as? [[String: Any]])
        for id in ["micro/marker", "micro/mrtProbe", "micro/samplerProbe"] {
            let record = try #require(corpusCases.first { $0["id"] as? String == id })
            let assets = try #require(record["assets"] as? [[String: Any]])
            let definition = try #require(assets.first {
                ($0["path"] as? String)?.hasSuffix(".portable.json") == true
            })
            let definitionText = try #require(definition["text"] as? String)
            var shaders: [(String, String)] = []
            for asset in assets where (asset["path"] as? String)?.hasSuffix(".wgsl") == true {
                let path = try #require(asset["path"] as? String)
                let source = try #require(asset["text"] as? String)
                let components = path.split(separator: "/").last!.split(separator: ".")
                shaders.append((String(components[components.count - 2]), source))
            }
            try registry.registerPortable(definitionJSON: Data(definitionText.utf8),
                                          orderedShaderSources: shaders)
        }
        let compiler = NoisemakerCompiler(registry: registry)
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"]
            .map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/reference")
        let directory = reference.appendingPathComponent("cases")
        let supported: Set<String> = ["solid", "compute", "computeFilter", "multipassBlur",
                                       "numericDefineOutsideChoices", "builtinEnum", "repeatFeedback",
                                       "mrtNoise3d", "resourceHeavy", "marker", "mrtProbe",
                                       "samplerProbe"]
        var compared = 0
        for name in supported.sorted() {
            let file = directory.appendingPathComponent("\(name).json")
            let caseFile = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let stages = try #require(caseFile["stages"] as? [String: Any])
            let source = try #require(stages["source"] as? String)
            let native = try compiler.compileStages(source: source)
            let expectedValidate = try ParserValue.decodeTagged(#require(stages["validate"]))
            let expectedExpand = try GraphValue.decode(#require(stages["expand"]))
            let expectedAllocate = try GraphValue.decode(#require(stages["allocate"]))
            let expectedGraph = try GraphValue.decode(#require(stages["graph"]))
            #expect(native.validated == expectedValidate, "\(name) validation")
            #expect(native.expanded.sameOrderedValue(as: expectedExpand), "\(name) expansion")
            #expect(native.allocations.sameOrderedValue(as: expectedAllocate), "\(name) allocation")
            #expect(native.graph.sameOrderedValue(as: expectedGraph), "\(name) graph")
            compared += 1
        }
        #expect(compared == 12)
    }

    @Test func nativeCompilerBuildsRenderableSolidGraph() throws {
        let compiler = try NoisemakerCompiler()
        let source = "search synth\nsolid(color: [0.2, 0.6, 0.9]).write(o0)\nrender(o0)\n"
        let graph = try compiler.compile(source: source)
        #expect(graph.passes.count == 2)
        #expect(graph.passes.map(\.id) == ["node_0_pass_0", "node_1_write_blit"])
        #expect(graph.renderSurface == "o0")
    }

    @Test func sourceCorpusSurfaceSubchainAndMediaStages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let corpus = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("parity/corpus.json"))) as? [String: Any])
        let records = try #require(corpus["cases"] as? [[String: Any]])
        let sources = Dictionary(uniqueKeysWithValues: records.compactMap { record -> (String, String)? in
            guard let id = record["id"] as? String, let source = record["source"] as? String else { return nil }
            return (id, source)
        })
        let compiler = try NoisemakerCompiler()

        let read = try compiler.compileStages(source: #require(sources["coverage/synth_reactionDiffusion"]))
        let readSteps = try #require(read.validated.field("plans")?.elements?[1].field("chain")?.elements)
        #expect(readSteps[0].field("args")?.field("tex")?.field("kind")?.string == "output")
        #expect(readSteps[0].field("args")?.field("tex")?.field("name")?.string == "o1")
        #expect(read.expanded.field("passes")?.arrayValue?[2].field("inputs")?
            .field("inputTex")?.stringValue == "global_o1")

        let subchain = try compiler.compileStages(source: #require(sources["curated/babylonjs_target_particles"]))
        let nested = try #require(subchain.validated.field("plans")?.elements?[0].field("chain")?.elements)
        #expect(nested.map { $0.field("op")?.string } == [
            "synth.perlin", "_subchain_begin", "render.pointsEmit", "points.flow",
            "render.pointsRender", "render.pointsBillboardRender", "_subchain_end",
            "filter.blur", "_write"
        ])
        #expect(nested[1].field("from")?.number == 0)
        #expect(nested[6].field("from")?.number == 5)

        let feedback = try compiler.compileStages(source: #require(sources["coverage/filter_convolutionFeedback"]))
        #expect(feedback.expanded.field("passes")?.arrayValue?[1].field("inputs")?
            .field("inputTex")?.stringValue == "global_o0")

        let media = try compiler.compileStages(source: #require(sources["coverage/synth_media"]))
        let mediaSteps = try #require(media.expanded.field("mediaSteps")?.arrayValue)
        #expect(mediaSteps.count == 1)
        #expect(mediaSteps[0].field("textureId")?.stringValue == "imageTex_step_0")
        #expect(mediaSteps[0].field("effect")?.stringValue == "synth.media")
        #expect(media.expanded.field("passes")?.arrayValue?[0].field("inputs")?
            .field("imageTex")?.stringValue == "imageTex_step_0")
    }
}
