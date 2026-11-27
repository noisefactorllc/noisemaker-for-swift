import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized) struct CompilerTests {
    @Test func portableForwardedOutputsRequireJavaScriptNonemptyNames() throws {
        let shader = ["probe": "@fragment fn main() {}"]
        let rejected: [Any] = [NSNull(), 7, false, "", " \t\n", "\u{FEFF}"]
        for field in ["outputTex", "outputXyz", "outputVel", "outputRgba"] {
            for value in rejected {
                var registry = try EffectRegistry.bundled()
                let definition: [String: Any] = ["namespace": "user", "func": "outputNameProbe",
                    "passes": [["program": "probe"]], field: value]
                let data = try JSONSerialization.data(withJSONObject: definition)
                expectThrows(try registry.registerPortable(definitionJSON: data, shaderSources: shader)) {
                    #expect($0 is CatalogError)
                }
                #expect(registry.effect(key: "user.outputNameProbe") == nil)
                #expect(registry.validatorOp("user.outputNameProbe") == nil)
            }
            for value in ["output", " inputTex ", "\u{0085}", "\u{200B}"] {
                var registry = try EffectRegistry.bundled()
                let definition: [String: Any] = ["namespace": "user", "func": "outputNameProbe",
                    "passes": [["program": "probe"]], field: value]
                try registry.registerPortable(definitionJSON:
                    JSONSerialization.data(withJSONObject: definition), shaderSources: shader)
                #expect(registry.effect(key: "user.outputNameProbe")?.definition.field(field)?.stringValue == value)
            }
        }
    }

    @Test func portableStorageTargetsScopeNamesAndPreserveAuthoredUsage() throws {
        var registry = try EffectRegistry.bundled()
        let definition = #"{"namespace":"user","func":"storageScopeProbe","starter":true,"textures":{"cache":{"width":8,"height":8,"usage":["sample"]}},"passes":[{"program":"fill","storageTextures":{"destination":"cache"},"workgroups":[1,1,1]},{"program":"show","inputs":{"source":"cache"},"outputs":{"color":"outputTex"}}]}"#
        try registry.registerPortable(definitionJSON: Data(definition.utf8), orderedShaderSources: [
            ("fill", "@compute @workgroup_size(1) fn main() {}"),
            ("show", "@fragment fn main() -> @location(0) vec4<f32> { return vec4<f32>(1.0); }")
        ])
        let stages = try NoisemakerCompiler(registry: registry).compileStages(source:
            "search user\nstorageScopeProbe().write(o0)\nrender(o0)\n")
        let fill = try #require(stages.expanded.field("passes")?.arrayValue?.first)
        #expect(fill.field("storageTextures")?.field("destination")?.stringValue == "node_0_cache")
        #expect(fill.field("outputs") == nil)
        let texture = try #require(stages.graph.field("textures")?.mapEntries?.first {
            $0.key.stringValue == "node_0_cache"
        })
        #expect(texture.value.field("usage")?.arrayValue?.compactMap(\.stringValue) == ["sample", "storage"])
    }

    @Test func triangleScreenCountIsAcceptedForMeshDimensionResolution() throws {
        var registry = try EffectRegistry.bundled()
        let definition = #"{"namespace":"user","func":"triangleScreenProbe","starter":true,"passes":[{"program":"probe","drawMode":"triangles","count":"screen","outputs":{"color":"outputTex"}}]}"#
        let shader = """
            @vertex fn vertexMain(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
                return vec4<f32>(0.0, 0.0, 0.0, 1.0);
            }
            @fragment fn main() -> @location(0) vec4<f32> { return vec4<f32>(1.0); }
            """
        try registry.registerPortable(definitionJSON: Data(definition.utf8), shaderSources: ["probe": shader])
        let graph = try NoisemakerCompiler(registry: registry).compile(source:
            "search user\ntriangleScreenProbe().write(o0)\nrender(o0)\n")
        #expect(graph.passes.first?.raw.field("count")?.stringValue == "screen")
    }

    @Test func portableStorageOutputRoutesInlineAndChainedWrites() throws {
        let fill = "@compute @workgroup_size(1) fn main() {}"
        let copy = "@fragment fn main() -> @location(0) vec4<f32> { return vec4<f32>(1.0); }"
        for explicitOutputs in [false, true] {
            var registry = try EffectRegistry.bundled()
            let outputs = explicitOutputs ? #", "outputs":{}"# : ""
            let producer = #"{"namespace":"user","func":"storageOutputProbe","starter":true,"passes":[{"program":"fill","workgroups":[1,1,1],"storageTextures":{"destination":"outputTex"}\#(outputs)}]}"#
            let consumer = #"{"namespace":"user","func":"storageCopyProbe","passes":[{"program":"copy","inputs":{"source":"inputTex"},"outputs":{"color":"outputTex"}}]}"#
            try registry.registerPortable(definitionJSON: Data(producer.utf8), shaderSources: ["fill": fill])
            try registry.registerPortable(definitionJSON: Data(consumer.utf8), shaderSources: ["copy": copy])
            for (chain, target) in [("storageOutputProbe()", "global_o0"),
                                    ("storageOutputProbe().storageCopyProbe()", "node_0_out")] {
                let stages = try NoisemakerCompiler(registry: registry).compileStages(source:
                    "search user\n\(chain).write(o0)\nrender(o0)\n")
                let passes = try #require(stages.expanded.field("passes")?.arrayValue)
                #expect(passes[0].field("storageTextures")?.field("destination")?.stringValue == target)
                #expect(stages.expanded.field("renderSurface")?.stringValue == "o0")
                #expect((passes[0].field("outputs") != nil) == explicitOutputs)
                if target == "node_0_out" {
                    #expect(passes[1].field("inputs")?.field("source")?.stringValue == target)
                    let texture = try #require(stages.graph.field("textures")?.mapEntries?.first {
                        $0.key.stringValue == target
                    })
                    #expect(texture.value.field("usage")?.arrayValue?.compactMap(\.stringValue) ==
                        ["render", "sample", "storage", "copySrc", "copyDst"])
                }
            }
        }
    }

    @Test func portableStorageMainOutputPreservesSourceStringUsage() throws {
        for usage in ["sample", "storage", "🟧"] {
            var registry = try EffectRegistry.bundled()
            let producer = #"{"namespace":"user","func":"storageOutputProbe","starter":true,"textures":{"out":{"width":8,"height":8,"usage":"\#(usage)"}},"passes":[{"program":"fill","workgroups":[1,1,1],"storageTextures":{"destination":"outputTex"}}]}"#
            let consumer = #"{"namespace":"user","func":"storageCopyProbe","passes":[{"program":"copy","inputs":{"source":"inputTex"},"outputs":{"color":"outputTex"}}]}"#
            try registry.registerPortable(definitionJSON: Data(producer.utf8),
                shaderSources: ["fill": "@compute @workgroup_size(1) fn main() {}"])
            try registry.registerPortable(definitionJSON: Data(consumer.utf8), shaderSources: [
                "copy": "@fragment fn main() -> @location(0) vec4<f32> { return vec4<f32>(1.0); }"
            ])
            let stages = try NoisemakerCompiler(registry: registry).compileStages(source:
                "search user\nstorageOutputProbe().storageCopyProbe().write(o0)\nrender(o0)\n")
            let actual = try #require(stages.graph.field("textures")?.mapEntries?.first {
                $0.key.stringValue == "node_0_out"
            }?.value.field("usage"))
            let expected: GraphValue = usage == "storage" ? .string(usage)
                : .array((usage.unicodeScalars.map { String($0) } + ["storage"]).map(GraphValue.string))
            #expect(actual.sameOrderedValue(as: expected))
        }
    }

    @Test func portableStorageVolumeCompilesWithoutRenderOutputs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("parity")
        let original = try #require(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("storage3d.portable.json"))) as? [String: Any])
        for usage in [nil, "sample", "storage"] as [String?] {
            var definition = original
            if let usage {
                var volumes = try #require(definition["textures3d"] as? [String: [String: Any]])
                volumes["volume"]?["usage"] = usage
                definition["textures3d"] = volumes
            }
            var registry = try EffectRegistry.bundled()
            try registry.registerPortable(definitionJSON:
                JSONSerialization.data(withJSONObject: definition), orderedShaderSources: [
                    ("fill", try String(contentsOf: root.appendingPathComponent("storage3d.fill.wgsl"), encoding: .utf8)),
                    ("show", try String(contentsOf: root.appendingPathComponent("storage3d.show.wgsl"), encoding: .utf8))
                ])
            let graph = try NoisemakerCompiler(registry: registry).compile(source:
                String(contentsOf: root.appendingPathComponent("storage3d.dsl"), encoding: .utf8))
            let fill = try #require(graph.passes.first)
            #expect(fill.outputs.isEmpty)
            #expect(fill.raw.field("outputs") == nil)
            #expect(fill.raw.field("storageTextures")?.field("volumeOut")?.stringValue == "node_0_volume")
            #expect(graph.persistentTextureNames.contains("node_0_volume"))
        }
    }

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
        let invalid = #"{"namespace":"user","func":"rejectedProbe","globals":{"gain":{"type":"float","default":1}},"paramAliases":{"old":"gain"},"passes":[{"program":"probe"}]}"#
        let shader = ["probe": "@fragment fn main() {}"]
        expectThrows(try registry.registerPortable(definitionJSON: Data(invalid.utf8),
                                                   shaderSources: shader)) { error in
            #expect(error is CatalogError)
        }
        #expect(registry.effects.count == count)
        #expect(registry.starterOps.count == starters)
        #expect(registry.effect(key: "user.rejectedProbe") == nil)
        #expect(registry.validatorOp("user.rejectedProbe") == nil)
        let valid = #"{"namespace":"user","func":"rejectedProbe","passes":[{"program":"probe"}]}"#
        try registry.registerPortable(definitionJSON: Data(valid.utf8), shaderSources: shader)
        #expect(registry.effects.count == count + 1)
        #expect(registry.effect(key: "user.rejectedProbe") != nil)
    }

    @Test func portableRegistrationMatchesSourceEntryPoint() throws {
        let base = #"{"name":"Portable Probe","namespace":"user","func":"portableProbe","globals":{"gain":{"type":"float","default":1}},"passes":[{"program":"probe","inputs":{},"outputs":{"color":"outputTex"}}]}"#
        let shader = ["probe": "@fragment fn main() {}"]
        let rejected: [(String, [String: String])] = [
            (base.replacingOccurrences(of: #""name":"Portable Probe","#, with: "")
                 .replacingOccurrences(of: #""func":"portableProbe","#, with: ""), shader),
            (base.replacingOccurrences(of: #""namespace":"user""#, with: #""namespace":"other""#), shader),
            (base.replacingOccurrences(of: #""namespace":"user""#, with: #""namespace":null"#), shader),
            (base.replacingOccurrences(of: #""namespace":"user""#, with: #""namespace":42"#), shader),
            (base.replacingOccurrences(of: #""func":"portableProbe""#, with: #""func":42"#), shader),
            (base.replacingOccurrences(of: #""namespace":"user","#, with: #""namespace":"user","starter":"yes","#), shader),
            (base.replacingOccurrences(of: #""program":"probe""#, with: #""program":"""#), shader),
            (base.replacingOccurrences(of: #""inputs":{}"#, with: #""inputs":{"src":""}"#), shader),
            (base.replacingOccurrences(of: #""outputs":{"color":"outputTex"}"#, with: #""outputs":["outputTex"]"#), shader),
            (base.replacingOccurrences(of: #""gain":{"type":"float","default":1}"#, with: #""gain":1"#), shader),
            (base.replacingOccurrences(of: #""default":1"#, with: #""default":1,"choices":{"bad":"word"}"#), shader),
            (base.replacingOccurrences(of: #""passes":"#, with: #""paramAliases":{"old":"gain"},"passes":"#), shader),
            (base.replacingOccurrences(of: #""namespace":"user","#, with: #""namespace":"user","toString":1,"#), shader),
            (base.replacingOccurrences(of: #""namespace":"user","#, with: #""namespace":"user","shaders":[],"#), shader),
            (base.replacingOccurrences(of: #""passes":[{"program":"probe","inputs":{},"outputs":{"color":"outputTex"}}]"#,
                with: #""passes":[{"program":"probe"},{"program":"other"}],"shaders":{"probe":{"glsl":"void main() {}"},"other":{}}"#),
             ["probe": "@fragment fn main() {}", "other": "@fragment fn main() {}"]),
            (base, ["probe": "  "])
        ]
        var registry = try EffectRegistry.bundled()
        let count = registry.effects.count
        let starters = registry.starterOps
        let ops = registry.validatorOps
        for (index, item) in rejected.enumerated() {
            expectThrows(try registry.registerPortable(definitionJSON: Data(item.0.utf8),
                                                       shaderSources: item.1)) { error in
                #expect(error is CatalogError, "rejected case \(index)")
            }
            #expect(registry.effects.count == count, "rejected case \(index)")
            #expect(registry.starterOps == starters, "rejected case \(index)")
            #expect(registry.validatorOps == ops, "rejected case \(index)")
            #expect(registry.effect(key: "user.portableProbe") == nil, "rejected case \(index)")
        }
        try registry.registerPortable(definitionJSON: Data(base.utf8), shaderSources: shader)
        #expect(registry.effect(key: "user.portableProbe") != nil)
        expectThrows(try registry.registerPortable(definitionJSON: Data(base.utf8),
                                                   shaderSources: shader)) { error in
            #expect(error is CatalogError)
        }
        #expect(registry.effects.count == count + 1)

        let accepted: [(String, Bool)] = [
            (base, true),
            (base.replacingOccurrences(of: #""name":"Portable Probe","#, with: ""), true),
            (base.replacingOccurrences(of: #""name":"Portable Probe""#, with: #""name":"portableProbe""#)
                .replacingOccurrences(of: #""func":"portableProbe","#, with: ""), true),
            (base.replacingOccurrences(of: #""name":"Portable Probe""#, with: #""name":"portableProbe""#)
                .replacingOccurrences(of: #""func":"portableProbe""#, with: #""func":null"#), true),
            (base.replacingOccurrences(of: #""namespace":"user","#, with: ""), true),
            (base.replacingOccurrences(of: #""namespace":"user","#, with: #""namespace":"user","starter":true,"#), true),
            (base.replacingOccurrences(of: #""namespace":"user","#, with: #""namespace":"user","starter":false,"#), false),
            (base.replacingOccurrences(of: #""type":"float""#, with: #""type":"nonsense""#), true),
            (base.replacingOccurrences(of: #""program":"probe""#, with: #""program":"probe","repeat":-1"#), true),
            (base.replacingOccurrences(of: #""inputs":{}"#, with: #""inputs":{"src":"unknownTex"}"#), true)
        ]
        for (index, item) in accepted.enumerated() {
            var fresh = try EffectRegistry.bundled()
            try fresh.registerPortable(definitionJSON: Data(item.0.utf8), shaderSources: shader)
            #expect(fresh.effect(key: "user.portableProbe") != nil, "accepted case \(index)")
            #expect(fresh.isStarter("user.portableProbe") == item.1, "accepted case \(index)")
        }
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

    @Test func retiredParameterAliasesAreUnknownArguments() throws {
        let compiler = try NoisemakerCompiler()
        _ = try compiler.compile(source: "search synth\nnoise(scaleX: 4).write(o0)\nrender(o0)\n")
        expectThrows(try compiler.compile(source: "search synth\nnoise(xScale: 4).write(o0)\nrender(o0)\n")) { error in
            #expect((error as? CompilationError)?.diagnostics == [CompilerDiagnostic(code: "S001",
                severity: "error", message: "Unknown argument 'xScale' for noise()",
                location: Noisemaker.SourceLocation(line: 2, column: 15))])
        }
    }

    @Test func parameterAliasCompilesAsItsCanonicalName() throws {
        let compiler = try NoisemakerCompiler()
        func passes(_ argument: String) throws -> GraphValue {
            let source = "search synth, points, render\nsolid().pointsEmit().flow(\(argument): o1).pointsRender().write(o0)\nrender(o0)\n"
            return try #require(compiler.compileStages(source: source).graph.field("passes"))
        }
        #expect(try passes("fieldTex").sameOrderedValue(as: passes("heightTex")))
    }

    @Test func vectorCallsSetVectorComponents() throws {
        let compiler = try NoisemakerCompiler()
        func firstArgument(_ source: String, _ name: String) throws -> ParserValue? {
            let validated = try compiler.compileStages(source: source).validated
            return validated.field("plans")?.elements?.first?.field("chain")?.elements?.first?
                .field("args")?.field(name)
        }
        #expect(try firstArgument("search synth\nmedia(imageSize: vec2(256, 128)).write(o0)\nrender(o0)\n",
                                  "imageSize") == .array([.number(256), .number(128)]))
        #expect(try firstArgument("search synth\nremap(zone0_bounds: vec4(0.1, 0.2, 0.7, 0.9)).write(o0)\nrender(o0)\n",
                                  "zone0_bounds") == .array([.number(0.1), .number(0.2), .number(0.7), .number(0.9)]))
    }

    @Test func portableFuncMustBeCallableFromSearchUser() throws {
        var registry = try EffectRegistry.bundled()
        let shader = ["probe": "@fragment fn main() {}"]
        for name in ["osc", "o1", "read", "let"] {
            let definition = #"{"namespace":"user","func":"\#(name)","passes":[{"program":"probe"}]}"#
            expectThrows(try registry.registerPortable(definitionJSON: Data(definition.utf8),
                                                       shaderSources: shader), name) { error in
                #expect(error is CatalogError, "\(name)")
            }
            #expect(registry.effect(key: "user.\(name)") == nil)
        }
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

    /// Source test_stateful_instances.js: each stateful effect instance in a
    /// chain owns its state texture and its zoom sizing parameter. The first
    /// instance keeps the legacy chain-scoped identifiers.
    @Test func statefulChainInstancesOwnTheirStateAndSizing() throws {
        let compiler = try NoisemakerCompiler()
        let source = "search synth, mixer\n" +
            "reactionDiffusion(zoom: x4).blendMode(tex: reactionDiffusion(zoom: x16)).write(o0)\n" +
            "render(o0)\n"
        let graph = try compiler.compile(source: source)
        let states = graph.textures.map(\.key)
            .filter { $0.hasPrefix("global_rd_state_chain_0") }.sorted()
        expectEqual(states.count, 2)
        expectTrue(states.contains("global_rd_state_chain_0"))
        expectTrue(states.contains { $0.hasPrefix("global_rd_state_chain_0_node_") })
        let sizes = states.compactMap { key -> (String, GraphDimension)? in
            let texture = graph.textures.first { $0.key == key }
            return texture.map { (key, $0.width) }
        }
        for (key, width) in sizes {
            guard case .screenDivide(let name, _) = width else {
                continue
            }
            let expectedZoom: Double
            if key == "global_rd_state_chain_0" {
                expectEqual(name, "zoom_chain_0")
                expectedZoom = 4
                expectEqual(try width.resolve(screen: 1024, parameters: graph.dimensionParameters), 256)
            } else {
                expectTrue(name.hasPrefix("zoom_chain_0_node_"))
                expectedZoom = 16
                expectEqual(try width.resolve(screen: 1024, parameters: graph.dimensionParameters), 64)
            }
            // Every pass of the owning instance scopes zoom to this parameter.
            for pass in graph.passes where pass.raw.field("effectFunc")?.stringValue == "reactionDiffusion" {
                guard let scoped = pass.raw.field("scopedParams")?.field("zoom")?.stringValue else {
                    continue
                }
                if scoped == name {
                    expectEqual(pass.uniforms.first { $0.name == scoped }?.value.numberValue, expectedZoom)
                }
            }
        }
        expectEqual(graph.dimensionParameters["zoom_chain_0"], 4)
        expectEqual(graph.dimensionParameters.first { $0.key.hasPrefix("zoom_chain_0_node_") }?.value, 16)
    }

    @Test func singleStatefulInstanceKeepsLegacyIdentifiers() throws {
        let compiler = try NoisemakerCompiler()
        let source = "search synth\nreactionDiffusion(zoom: x8).write(o0)\nrender(o0)\n"
        let graph = try compiler.compile(source: source)
        expectTrue(graph.textures.map(\.key).contains("global_rd_state_chain_0"))
        expectEqual(graph.dimensionParameters["zoom_chain_0"], 8)
    }
}
