import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct GraphTests {
    private func fixture() throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent(".build/reference/cases/solid.json"))
    }

    private func caseData(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent(".build/reference/cases/\(name).json"))
    }

    private func changingGraph(_ data: Data, _ change: (inout [[Any]]) throws -> Void) throws -> Data {
        var root = try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stages = try requireValue(root["stages"] as? [String: Any])
        var graph = try requireValue(stages["graph"] as? [String: Any])
        var fields = try requireValue(graph["entries"] as? [[Any]])
        try change(&fields)
        graph["entries"] = fields
        stages["graph"] = graph
        root["stages"] = stages
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func changeTexture(_ graphFields: inout [[Any]], name: String,
                               field: String, to value: Any) throws {
        let index = try requireValue(graphFields.firstIndex { ($0.first as? String) == "textures" })
        var map = try requireValue(graphFields[index][1] as? [String: Any])
        var entries = try requireValue(map["entries"] as? [[Any]])
        let textureIndex = try requireValue(entries.firstIndex { ($0.first as? String) == name })
        var spec = try requireValue(entries[textureIndex][1] as? [String: Any])
        var specFields = try requireValue(spec["entries"] as? [[Any]])
        let fieldIndex = try requireValue(specFields.firstIndex { ($0.first as? String) == field })
        specFields[fieldIndex][1] = value
        spec["entries"] = specFields
        entries[textureIndex][1] = spec
        map["entries"] = entries
        graphFields[index][1] = map
    }

    private func addUniform(_ graphFields: inout [[Any]], pass index: Int,
                            name: String, value: Any) throws {
        let passesIndex = try requireValue(graphFields.firstIndex { ($0.first as? String) == "passes" })
        var passes = try requireValue(graphFields[passesIndex][1] as? [[String: Any]])
        var pass = passes[index]
        var fields = try requireValue(pass["entries"] as? [[Any]])
        let uniformsIndex = try requireValue(fields.firstIndex { ($0.first as? String) == "uniforms" })
        var uniforms = try requireValue(fields[uniformsIndex][1] as? [String: Any])
        var entries = try requireValue(uniforms["entries"] as? [[Any]])
        entries.append([name, value])
        uniforms["entries"] = entries
        fields[uniformsIndex][1] = uniforms
        pass["entries"] = fields
        passes[index] = pass
        graphFields[passesIndex][1] = passes
    }

    @Test func testTaggedGraphPreservesOrderUndefinedAndMaps() throws {
        let graph = try RenderGraph(exportedCaseData: fixture())
        expectEqual(graph.id, "s6t6rt")
        expectEqual(graph.passes.map(\.id), ["node_0_pass_0", "node_1_write_blit"])
        expectEqual(graph.textures.map(\.key), ["node_0_out"])
        expectEqual(graph.allocations.map(\.key), ["node_0_out"])
        expectTrue(graph.passes[0].raw.field("clear")?.isUndefined == true)
        expectTrue(graph.passes[0].raw.field("entryPoint")?.isUndefined == true)
        expectEqual(graph.programs["node_0_solid"]?.resolvedWGSL.contains("@fragment"), true)
    }

    @Test func testSourceUniformAliasesRetainTheirResolvedPassValues() throws {
        let source = """
            search synth, classicNoisedeck
            noise(seed: 1, scaleX: 50, scaleY: 50).refract().write(o0)
            render(o0)
            """
        let graph = try NoisemakerCompiler().compile(source: source)
        let aliased = graph.passes.filter {
            $0.raw.field("uniformAliases")?.objectFields?.isEmpty == false
        }
        expectTrue(!aliased.isEmpty)
        for pass in aliased {
            for mapping in pass.raw.field("uniformAliases")?.objectFields ?? [] {
                expectTrue(mapping.value.stringValue?.isEmpty == false)
                expectTrue(pass.uniforms.contains(where: { $0.name == mapping.name }))
            }
        }
    }

    @Test func testSourceBloomPreservesWebGPUHalfFloatFormat() throws {
        let source = """
            search filter, synth
            solid(color: #000000).bloom().write(o0)
            """
        let graph = try NoisemakerCompiler().compile(source: source)
        expectEqual(graph.textures.first(where: { $0.key == "node_1__brightTex" })?.format,
            "rgba16float")
    }

    @Test func testGraphAcceptsOptInMipChainOnTwoDimensionalTexture() throws {
        let data = try changingGraph(fixture()) { fields in
            let index = try requireValue(fields.firstIndex { ($0.first as? String) == "textures" })
            var map = try requireValue(fields[index][1] as? [String: Any])
            var entries = try requireValue(map["entries"] as? [[Any]])
            var spec = try requireValue(entries[0][1] as? [String: Any])
            var specFields = try requireValue(spec["entries"] as? [[Any]])
            specFields.append(["mipmaps", true])
            spec["entries"] = specFields
            entries[0][1] = spec
            map["entries"] = entries
            fields[index][1] = map
        }
        let graph = try RenderGraph(exportedCaseData: data)
        expectEqual(graph.textures[0].raw.field("mipmaps")?.boolValue, true)
    }

    @Test func testPassConditionsCompareRawUniformsBeforeAutomation() throws {
        let automation: GraphValue = .object([
            GraphField(name: "type", value: .string("Midi")),
            GraphField(name: "mode", value: .number(5)),
            GraphField(name: "channel", value: .number(1)),
            GraphField(name: "cc", value: .undefined)
        ])
        let pass = GraphPass(id: "conditional", program: "noop", raw: .object([]),
            inputs: [], outputs: [],
            uniforms: [GraphField(name: "gate", value: automation)],
            entryPoint: "main", repeatCount: 1)
        let conditions = GraphConditions(skipIf: [],
            runIf: [GraphPredicate(uniform: "gate", equals: .number(1))])
        let inputs = AutomationInputs(midi: MIDIInputSnapshot(aggregate:
            MIDIStateSnapshot(channels: [1: MIDIChannelSnapshot(cc: [1: 127])])))
        let frame = FrameState(time: 0, delta: 0, frameIndex: 0, inputs: inputs)
        // Pipeline.shouldSkipPass compares the tagged object by JS identity
        // before WebGPU resolves it to a numeric binding. It cannot equal 1.
        expectTrue(conditions.shouldSkip(pass: pass, frame: frame))
    }

    @Test func testLiteralDimensionsFloorThenClampLikeSource() throws {
        for literal in [0.256, 0, -3.5] {
            let dimension = try GraphDimension.decode(.number(literal), context: "literal")
            expectEqual(try dimension.resolve(screen: 257, parameters: [:]), 1)
        }
        let edge = try GraphDimension.decode(.number(16_384.9), context: "literal")
        expectEqual(try edge.resolve(screen: 257, parameters: [:]), 16_384)
        expectThrows(try GraphDimension.decode(.number(16_385), context: "literal"))
        expectThrows(try GraphDimension.decode(.number(.infinity), context: "literal"))
    }

    @Test func testSourceWormholeRetainsPointDrawAndVertexEntry() throws {
        let source = """
            search synth, filter
            noise(seed: 1, scaleX: 50, scaleY: 50).wormhole().write(o0)
            render(o0)
            """
        let graph = try NoisemakerCompiler().compile(source: source)
        let deposit = try requireValue(graph.passes.first(where: {
            $0.raw.field("drawMode")?.stringValue == "points"
        }))
        expectEqual(deposit.raw.field("count")?.stringValue, "input")
        expectEqual(graph.programs[deposit.program]?.vertexEntryPoint, "vertexMain")
        expectEqual(deposit.inputs.first(where: { $0.key == "inputTex" })?.value.stringValue,
            "node_0_out")
    }

    @Test func testSourceMeshGlobalsAreExternalAndTriangleDrawUsesVertexEntry() throws {
        let source = """
            search render
            meshLoader().meshRender().write(o0)
            render(o0)
            """
        let graph = try NoisemakerCompiler().compile(source: source)
        expectTrue(graph.externalTextureNames.contains("global_mesh0_positions_chain_0"))
        expectTrue(graph.externalTextureNames.contains("global_mesh0_normals_chain_0"))
        expectTrue(!graph.globalSurfaceNames.contains("mesh0_positions_chain_0"))
        let draw = try requireValue(graph.passes.first(where: {
            $0.raw.field("drawMode")?.stringValue == "triangles"
        }))
        expectEqual(draw.raw.field("count")?.stringValue, "input")
        expectEqual(graph.programs[draw.program]?.vertexEntryPoint, "vs_main")
    }

    @Test func testSourceBillboardConditionsSelectOnlyCurrentViewAndBlend() throws {
        let source = """
            search synth, render
            solid().pointsEmit(stateSize: 128).pointsBillboardRender().write(o0)
            render(o0)
            """
        let graph = try NoisemakerCompiler().compile(source: source)
        let skippedDepth = try requireValue(graph.passes.first(where: {
            $0.id == "node_2_pass_0"
        }))
        let skippedBillboard = try requireValue(graph.passes.first(where: {
            $0.id == "node_2_pass_27"
        }))
        let activeBillboard = try requireValue(graph.passes.first(where: {
            $0.id == "node_2_pass_31"
        }))
        expectTrue(skippedDepth.conditions?.shouldSkip(pass: skippedDepth,
            frame: .zero) == true)
        expectTrue(skippedBillboard.conditions?.shouldSkip(pass: skippedBillboard,
            frame: .zero) == true)
        expectTrue(activeBillboard.conditions?.shouldSkip(pass: activeBillboard,
            frame: .zero) == false)
    }

    @Test func testSourceFeedbackTextureIsPersistentBeforeItsFirstWrite() throws {
        let source = """
            search synth, filter
            noise(seed: 1, scaleX: 50, scaleY: 50).feedback(mix: 50, scaleAmt: 110).write(o0)
            render(o0)
            """
        let graph = try NoisemakerCompiler().compile(source: source)
        expectTrue(graph.persistentTextureNames.contains("node_1__selfTex"))
        expectTrue(graph.allocations.contains(where: { $0.key == "node_1__selfTex" }))
        expectTrue(graph.textures.contains(where: { $0.key == "node_1__selfTex" }))
    }

    @Test func testSourceCanPresentAnEarlierGlobalOutput() throws {
        let source = """
            search synth
            solid(color: #ff0000).write(o0)
            solid(color: #0000ff).write(o1)
            render(o0)
            """
        let graph = try NoisemakerCompiler().compile(source: source)
        expectEqual(graph.renderSurface, "o0")
        expectEqual(graph.passes.first?.outputs.first?.value.stringValue, "node_0_out")
        expectEqual(graph.passes.last?.outputs.first?.value.stringValue, "global_o1")
        expectTrue(graph.globalSurfaceNames.contains("o0"))
        expectTrue(graph.globalSurfaceNames.contains("o1"))
    }

    @Test func testSourceRollUsesNativeMIDIGridAndPersistentFeedback() throws {
        let source = """
            search synth
            roll().write(o0)
            render(o0)
            """
        let graph = try NoisemakerCompiler().compile(source: source)
        expectTrue(graph.externalTextureNames.contains("midiNoteGrid"))
        expectTrue(graph.persistentTextureNames.contains("node_0__rollFb"))
    }

    @Test func testSourceCPUOverlayIsAnExplicitExternalTexture() throws {
        let source = """
            search filter, synth
            solid(color: #000000).fibers(alpha: 1).write(o0)
            render(o0)
            """
        let graph = try NoisemakerCompiler().compile(source: source)
        expectEqual(graph.externalTextureNames, ["node_1_overlayTex"])
        expectFalse(graph.allocations.contains(where: { $0.key == "node_1_overlayTex" }))
        expectTrue(graph.textures.contains(where: { $0.key == "node_1_overlayTex" }))
    }

    @Test func testUnproducedDeclaredVolumeGeometryIsGraphOwned() throws {
        let source = """
            search synth3d, filter3d, render
            noise3d().flow3d().render3d().write(o0)
            render(o0)
            """
        let graph = try NoisemakerCompiler().compile(source: source)
        expectTrue(graph.textures.contains(where: { $0.key == "node_1_geoBuffer" }))
        expectTrue(graph.passes.contains(where: { pass in
            pass.inputs.contains(where: { $0.value.stringValue == "node_1_geoBuffer" })
        }))
        expectFalse(graph.passes.contains(where: { pass in
            pass.outputs.contains(where: { $0.value.stringValue == "node_1_geoBuffer" })
        }))
        expectFalse(graph.externalTextureNames.contains("node_1_geoBuffer"))
        expectTrue(graph.externalTextureNames.isEmpty)
    }

    @Test func testUnknownExecutionFieldIsRejected() throws {
        let data = try fixture()
        var root = try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stages = try requireValue(root["stages"] as? [String: Any])
        var taggedGraph = try requireValue(stages["graph"] as? [String: Any])
        var entries = try requireValue(taggedGraph["entries"] as? [[Any]])
        let passesIndex = try requireValue(entries.firstIndex { ($0.first as? String) == "passes" })
        var passes = try requireValue(entries[passesIndex][1] as? [[String: Any]])
        var firstPass = passes[0]
        var passEntries = try requireValue(firstPass["entries"] as? [[Any]])
        passEntries.append(["newExecutionMode", true])
        firstPass["entries"] = passEntries
        passes[0] = firstPass
        entries[passesIndex][1] = passes
        taggedGraph["entries"] = entries
        stages["graph"] = taggedGraph
        root["stages"] = stages
        let changed = try JSONSerialization.data(withJSONObject: root)
        expectThrows(try RenderGraph(exportedCaseData: changed))
    }

    @Test func testRepeatCountFollowsExportedUniformAndRejectsUnboundedValues() throws {
        let feedback = try RenderGraph(exportedCaseData: caseData("repeatFeedback"))
        expectEqual(feedback.passes.first?.repeatCount, 2)
        expectEqual(feedback.globalSurfaceNames, ["o0", "rd_state_chain_0"])
        let data = try fixture()
        var root = try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stages = try requireValue(root["stages"] as? [String: Any])
        var taggedGraph = try requireValue(stages["graph"] as? [String: Any])
        var entries = try requireValue(taggedGraph["entries"] as? [[Any]])
        let passesIndex = try requireValue(entries.firstIndex { ($0.first as? String) == "passes" })
        var passes = try requireValue(entries[passesIndex][1] as? [[String: Any]])
        var firstPass = passes[0]
        var passEntries = try requireValue(firstPass["entries"] as? [[Any]])
        let repeatIndex = try requireValue(passEntries.firstIndex { ($0.first as? String) == "repeat" })
        passEntries[repeatIndex][1] = 2
        firstPass["entries"] = passEntries
        passes[0] = firstPass
        entries[passesIndex][1] = passes
        taggedGraph["entries"] = entries
        stages["graph"] = taggedGraph
        root["stages"] = stages
        let changed = try JSONSerialization.data(withJSONObject: root)
        expectEqual(try RenderGraph(exportedCaseData: changed).passes.first?.repeatCount, 2)
        passEntries[repeatIndex][1] = 257
        firstPass["entries"] = passEntries
        passes[0] = firstPass
        entries[passesIndex][1] = passes
        taggedGraph["entries"] = entries
        stages["graph"] = taggedGraph
        root["stages"] = stages
        expectThrows(try RenderGraph(exportedCaseData: JSONSerialization.data(withJSONObject: root)))
        passEntries[repeatIndex][1] = "missingIterationUniform"
        firstPass["entries"] = passEntries
        passes[0] = firstPass
        entries[passesIndex][1] = passes
        taggedGraph["entries"] = entries
        stages["graph"] = taggedGraph
        root["stages"] = stages
        expectThrows(try RenderGraph(exportedCaseData: JSONSerialization.data(withJSONObject: root)))
    }
    @Test func testExplicitClearFalseUsesLoadAndMalformedClearRefuses() throws {
        let data = try fixture()
        var root = try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stages = try requireValue(root["stages"] as? [String: Any])
        var taggedGraph = try requireValue(stages["graph"] as? [String: Any])
        var entries = try requireValue(taggedGraph["entries"] as? [[Any]])
        let passesIndex = try requireValue(entries.firstIndex { ($0.first as? String) == "passes" })
        var passes = try requireValue(entries[passesIndex][1] as? [[String: Any]])
        var first = passes[0]
        var fields = try requireValue(first["entries"] as? [[Any]])
        let clearIndex = try requireValue(fields.firstIndex { ($0.first as? String) == "clear" })
        fields[clearIndex][1] = false
        first["entries"] = fields
        passes[0] = first
        entries[passesIndex][1] = passes
        taggedGraph["entries"] = entries
        stages["graph"] = taggedGraph
        root["stages"] = stages
        let accepted = try RenderGraph(exportedCaseData: JSONSerialization.data(withJSONObject: root))
        guard case .bool(false) = accepted.passes[0].raw.field("clear") else {
            return recordFailure("expected explicit false clear")
        }
        fields[clearIndex][1] = "sometimes"
        first["entries"] = fields
        passes[0] = first
        entries[passesIndex][1] = passes
        taggedGraph["entries"] = entries
        stages["graph"] = taggedGraph
        root["stages"] = stages
        expectThrows(try RenderGraph(exportedCaseData: JSONSerialization.data(withJSONObject: root)))
    }

    @Test func testMarkerGraphRetainsAsymmetricTwoPassProgram() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let graph = try RenderGraph(exportedCaseData:
            Data(contentsOf: root.appendingPathComponent(".build/reference/cases/marker.json")))
        expectEqual(graph.passes.count, 2)
        expectEqual(graph.passes[0].outputs.first?.value.stringValue, "node_0_out")
        expectEqual(graph.passes[1].inputs.first?.value.stringValue, "node_0_out")
        expectEqual(graph.passes[1].outputs.first?.value.stringValue, "global_o0")
    }

    @Test func testFeedbackTextureIsRejectedBeforeEncoding() throws {
        let data = try fixture()
        var root = try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stages = try requireValue(root["stages"] as? [String: Any])
        var graph = try requireValue(stages["graph"] as? [String: Any])
        var fields = try requireValue(graph["entries"] as? [[Any]])
        let passIndex = try requireValue(fields.firstIndex { ($0.first as? String) == "passes" })
        var passes = try requireValue(fields[passIndex][1] as? [[String: Any]])
        var first = passes[0]
        var passFields = try requireValue(first["entries"] as? [[Any]])
        let inputIndex = try requireValue(passFields.firstIndex { ($0.first as? String) == "inputs" })
        passFields[inputIndex][1] = ["$type": "object", "entries": [["src", "node_0_out"]]]
        first["entries"] = passFields
        passes[0] = first
        fields[passIndex][1] = passes
        graph["entries"] = fields
        stages["graph"] = graph
        root["stages"] = stages
        expectThrows(try RenderGraph(exportedCaseData: JSONSerialization.data(withJSONObject: root)))
    }

    @Test func testTextureDimensionParameterFallbackMatchesUpstreamTransformOrder() throws {
        let plain = GraphValue.object([
            GraphField(name: "param", value: .string("size")),
            GraphField(name: "default", value: .number(256))
        ])
        let plainDimension = try GraphDimension.decode(plain, context: "plain")
        expectEqual(try plainDimension.resolve(screen: 257, parameters: [:]), 64)
        expectEqual(try plainDimension.resolve(screen: 257, parameters: ["size": 16]), 16)
        let squared = GraphValue.object([
            GraphField(name: "param", value: .string("size")),
            GraphField(name: "power", value: .number(2)),
            GraphField(name: "default", value: .number(4096))
        ])
        let squaredDimension = try GraphDimension.decode(squared, context: "squared")
        expectEqual(try squaredDimension.resolve(screen: 257, parameters: [:]), 4096)
        expectEqual(try squaredDimension.resolve(screen: 257, parameters: ["size": 16]), 256)
    }

    @Test func testInputOverrideDimensionRetainsSourceParameterResolution() throws {
        let value: GraphValue = .object([
            GraphField(name: "param", value: .string("volumeSize")),
            GraphField(name: "power", value: .number(2)),
            GraphField(name: "default", value: .number(1024)),
            GraphField(name: "inputOverride", value: .string("inputTex3d"))
        ])
        let dimension = try GraphDimension.decode(value, context: "viewport height")
        expectEqual(try dimension.resolve(screen: 129, parameters: ["volumeSize": 16]), 256)
        expectEqual(try dimension.resolve(screen: 129, parameters: [:]), 1024)
        let invalid: GraphValue = .object([
            GraphField(name: "param", value: .string("volumeSize")),
            GraphField(name: "inputOverride", value: .number(2))
        ])
        expectThrows(try GraphDimension.decode(invalid, context: "viewport height"))
    }

    @Test func testMalformedTextureDimensionDoesNotCoerceToFallback() throws {
        let malformed = GraphValue.object([
            GraphField(name: "param", value: .string("size")),
            GraphField(name: "power", value: .string("two"))
        ])
        expectThrows(try GraphDimension.decode(malformed, context: "bad"))
    }

    @Test func testScaleClampDimensionUsesUpstreamFloorThenBounds() throws {
        let scaled = GraphValue.object([
            GraphField(name: "scale", value: .number(0.25)),
            GraphField(name: "clamp", value: .object([
                GraphField(name: "min", value: .number(16)),
                GraphField(name: "max", value: .number(48))
            ]))
        ])
        let dimension = try GraphDimension.decode(scaled, context: "scaled")
        expectEqual(try dimension.resolve(screen: 129, parameters: [:]), 32)
        expectEqual(try dimension.resolve(screen: 32, parameters: [:]), 16)
        expectEqual(try dimension.resolve(screen: 300, parameters: [:]), 48)
        let malformed = GraphValue.object([
            GraphField(name: "scale", value: .number(0.25)),
            GraphField(name: "clamp", value: .object([
                GraphField(name: "min", value: .string("small"))
            ]))
        ])
        expectThrows(try GraphDimension.decode(malformed, context: "malformed"))
    }

    @Test func testSourceExportedComputeAndMRTGraphsKeepPassOrderAndFormats() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let compute = try RenderGraph(exportedCaseData:
            Data(contentsOf: root.appendingPathComponent(".build/reference/cases/computeFilter.json")))
        expectEqual(compute.passes.count, 3)
        expectEqual(compute.programs[compute.passes[1].program]?.stage, .compute)
        expectEqual(compute.passes[1].outputs.first?.value.stringValue, "node_1_out")
        let blur = try RenderGraph(exportedCaseData:
            Data(contentsOf: root.appendingPathComponent(".build/reference/cases/multipassBlur.json")))
        expectEqual(blur.passes.count, 4)
        expectEqual(blur.textures.first(where: { $0.key == "node_1__blurTemp" })?.format, "rgba8unorm")
        let mrt = try RenderGraph(exportedCaseData:
            Data(contentsOf: root.appendingPathComponent(".build/reference/cases/mrtProbe.json")))
        expectEqual(mrt.passes.first?.outputs.map(\.key), ["first", "second"])
        expectEqual(mrt.passes[1].inputs.map(\.key), ["firstTex", "secondTex"])
    }

    @Test func testTaggedNumbersPreserveSpecialValuesAndUnknownTagsRefuse() throws {
        let decoded = try GraphValue.decode(["$type": "number", "value": "-0"])
        guard case .number(let value) = decoded else { return recordFailure("Expected tagged number") }
        expectEqual(value, 0)
        expectEqual(Float(value).bitPattern, Float(-0.0).bitPattern)
        let nan = try GraphValue.decode(["$type": "number", "value": "NaN"])
        expectTrue(nan.numberValue?.isNaN == true)
        let positive = try GraphValue.decode(["$type": "number", "value": "Infinity"])
        expectEqual(positive.numberValue, Double.infinity)
        let negative = try GraphValue.decode(["$type": "number", "value": "-Infinity"])
        expectEqual(negative.numberValue, -Double.infinity)
        expectThrows(try GraphValue.decode(["$type": "number", "value": "not-a-number"]))
    }

    @Test func testComputeTargetWithNonScreenDimensionsRefusesBeforeEncoding() throws {
        let changed = try changingGraph(caseData("computeFilter")) { fields in
            try changeTexture(&fields, name: "node_1_out", field: "width", to: 128)
        }
        let graph = try RenderGraph(exportedCaseData: changed)
        expectThrows(try graph.validateDimensions(for: RenderSize(width: 257, height: 129)))
    }

    @Test func testNonNumericScreenDivisorRefusesAndNumericUsesLastPass() throws {
        let divisor: [String: Any] = ["$type": "object", "entries": [["screenDivide", "zoom"]]]
        let nonnumeric = try changingGraph(fixture()) { fields in
            try changeTexture(&fields, name: "node_0_out", field: "width", to: divisor)
            try addUniform(&fields, pass: 0, name: "zoom", value: [
                "$type": "object", "entries": [["oscillator", "unresolved"]]
            ])
        }
        expectThrows(try RenderGraph(exportedCaseData: nonnumeric))
        let varying = try changingGraph(fixture()) { fields in
            try changeTexture(&fields, name: "node_0_out", field: "width", to: divisor)
            try addUniform(&fields, pass: 0, name: "zoom", value: 2)
            try addUniform(&fields, pass: 1, name: "zoom", value: 3)
        }
        let graph = try RenderGraph(exportedCaseData: varying)
        expectEqual(graph.dimensionParameters["zoom"], 3)
    }

}
