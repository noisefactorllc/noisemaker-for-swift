import Foundation
import XCTest
@testable import Noisemaker

final class GraphTests: XCTestCase {
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
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stages = try XCTUnwrap(root["stages"] as? [String: Any])
        var graph = try XCTUnwrap(stages["graph"] as? [String: Any])
        var fields = try XCTUnwrap(graph["entries"] as? [[Any]])
        try change(&fields)
        graph["entries"] = fields
        stages["graph"] = graph
        root["stages"] = stages
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func changeTexture(_ graphFields: inout [[Any]], name: String,
                               field: String, to value: Any) throws {
        let index = try XCTUnwrap(graphFields.firstIndex { ($0.first as? String) == "textures" })
        var map = try XCTUnwrap(graphFields[index][1] as? [String: Any])
        var entries = try XCTUnwrap(map["entries"] as? [[Any]])
        let textureIndex = try XCTUnwrap(entries.firstIndex { ($0.first as? String) == name })
        var spec = try XCTUnwrap(entries[textureIndex][1] as? [String: Any])
        var specFields = try XCTUnwrap(spec["entries"] as? [[Any]])
        let fieldIndex = try XCTUnwrap(specFields.firstIndex { ($0.first as? String) == field })
        specFields[fieldIndex][1] = value
        spec["entries"] = specFields
        entries[textureIndex][1] = spec
        map["entries"] = entries
        graphFields[index][1] = map
    }

    private func addUniform(_ graphFields: inout [[Any]], pass index: Int,
                            name: String, value: Any) throws {
        let passesIndex = try XCTUnwrap(graphFields.firstIndex { ($0.first as? String) == "passes" })
        var passes = try XCTUnwrap(graphFields[passesIndex][1] as? [[String: Any]])
        var pass = passes[index]
        var fields = try XCTUnwrap(pass["entries"] as? [[Any]])
        let uniformsIndex = try XCTUnwrap(fields.firstIndex { ($0.first as? String) == "uniforms" })
        var uniforms = try XCTUnwrap(fields[uniformsIndex][1] as? [String: Any])
        var entries = try XCTUnwrap(uniforms["entries"] as? [[Any]])
        entries.append([name, value])
        uniforms["entries"] = entries
        fields[uniformsIndex][1] = uniforms
        pass["entries"] = fields
        passes[index] = pass
        graphFields[passesIndex][1] = passes
    }

    func testTaggedGraphPreservesOrderUndefinedAndMaps() throws {
        let graph = try RenderGraph(exportedCaseData: fixture())
        XCTAssertEqual(graph.id, "s6t6rt")
        XCTAssertEqual(graph.passes.map(\.id), ["node_0_pass_0", "node_1_write_blit"])
        XCTAssertEqual(graph.textures.map(\.key), ["node_0_out"])
        XCTAssertEqual(graph.allocations.map(\.key), ["node_0_out"])
        XCTAssertTrue(graph.passes[0].raw.field("clear")?.isUndefined == true)
        XCTAssertTrue(graph.passes[0].raw.field("entryPoint")?.isUndefined == true)
        XCTAssertEqual(graph.programs["node_0_solid"]?.resolvedWGSL.contains("@fragment"), true)
    }

    func testUnknownExecutionFieldIsRejected() throws {
        let data = try fixture()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stages = try XCTUnwrap(root["stages"] as? [String: Any])
        var taggedGraph = try XCTUnwrap(stages["graph"] as? [String: Any])
        var entries = try XCTUnwrap(taggedGraph["entries"] as? [[Any]])
        let passesIndex = try XCTUnwrap(entries.firstIndex { ($0.first as? String) == "passes" })
        var passes = try XCTUnwrap(entries[passesIndex][1] as? [[String: Any]])
        var firstPass = passes[0]
        var passEntries = try XCTUnwrap(firstPass["entries"] as? [[Any]])
        passEntries.append(["newExecutionMode", true])
        firstPass["entries"] = passEntries
        passes[0] = firstPass
        entries[passesIndex][1] = passes
        taggedGraph["entries"] = entries
        stages["graph"] = taggedGraph
        root["stages"] = stages
        let changed = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try RenderGraph(exportedCaseData: changed))
    }

    func testPresentUnsupportedRepeatIsRejected() throws {
        let data = try fixture()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stages = try XCTUnwrap(root["stages"] as? [String: Any])
        var taggedGraph = try XCTUnwrap(stages["graph"] as? [String: Any])
        var entries = try XCTUnwrap(taggedGraph["entries"] as? [[Any]])
        let passesIndex = try XCTUnwrap(entries.firstIndex { ($0.first as? String) == "passes" })
        var passes = try XCTUnwrap(entries[passesIndex][1] as? [[String: Any]])
        var firstPass = passes[0]
        var passEntries = try XCTUnwrap(firstPass["entries"] as? [[Any]])
        let repeatIndex = try XCTUnwrap(passEntries.firstIndex { ($0.first as? String) == "repeat" })
        passEntries[repeatIndex][1] = 2
        firstPass["entries"] = passEntries
        passes[0] = firstPass
        entries[passesIndex][1] = passes
        taggedGraph["entries"] = entries
        stages["graph"] = taggedGraph
        root["stages"] = stages
        let changed = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try RenderGraph(exportedCaseData: changed))
    }
    func testExplicitClearFalseIsRejected() throws {
        let data = try fixture()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stages = try XCTUnwrap(root["stages"] as? [String: Any])
        var taggedGraph = try XCTUnwrap(stages["graph"] as? [String: Any])
        var entries = try XCTUnwrap(taggedGraph["entries"] as? [[Any]])
        let passesIndex = try XCTUnwrap(entries.firstIndex { ($0.first as? String) == "passes" })
        var passes = try XCTUnwrap(entries[passesIndex][1] as? [[String: Any]])
        var first = passes[0]
        var fields = try XCTUnwrap(first["entries"] as? [[Any]])
        let clearIndex = try XCTUnwrap(fields.firstIndex { ($0.first as? String) == "clear" })
        fields[clearIndex][1] = false
        first["entries"] = fields
        passes[0] = first
        entries[passesIndex][1] = passes
        taggedGraph["entries"] = entries
        stages["graph"] = taggedGraph
        root["stages"] = stages
        XCTAssertThrowsError(try RenderGraph(exportedCaseData: JSONSerialization.data(withJSONObject: root)))
    }

    func testMarkerGraphRetainsAsymmetricTwoPassProgram() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let graph = try RenderGraph(exportedCaseData:
            Data(contentsOf: root.appendingPathComponent(".build/reference/cases/marker.json")))
        XCTAssertEqual(graph.passes.count, 2)
        XCTAssertEqual(graph.passes[0].outputs.first?.value.stringValue, "node_0_out")
        XCTAssertEqual(graph.passes[1].inputs.first?.value.stringValue, "node_0_out")
        XCTAssertEqual(graph.passes[1].outputs.first?.value.stringValue, "global_o0")
    }

    func testFeedbackTextureIsRejectedBeforeEncoding() throws {
        let data = try fixture()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stages = try XCTUnwrap(root["stages"] as? [String: Any])
        var graph = try XCTUnwrap(stages["graph"] as? [String: Any])
        var fields = try XCTUnwrap(graph["entries"] as? [[Any]])
        let passIndex = try XCTUnwrap(fields.firstIndex { ($0.first as? String) == "passes" })
        var passes = try XCTUnwrap(fields[passIndex][1] as? [[String: Any]])
        var first = passes[0]
        var passFields = try XCTUnwrap(first["entries"] as? [[Any]])
        let inputIndex = try XCTUnwrap(passFields.firstIndex { ($0.first as? String) == "inputs" })
        passFields[inputIndex][1] = ["$type": "object", "entries": [["src", "node_0_out"]]]
        first["entries"] = passFields
        passes[0] = first
        fields[passIndex][1] = passes
        graph["entries"] = fields
        stages["graph"] = graph
        root["stages"] = stages
        XCTAssertThrowsError(try RenderGraph(exportedCaseData: JSONSerialization.data(withJSONObject: root)))
    }

    func testTextureDimensionParameterFallbackMatchesUpstreamTransformOrder() throws {
        let plain = GraphValue.object([
            GraphField(name: "param", value: .string("size")),
            GraphField(name: "default", value: .number(256))
        ])
        let plainDimension = try GraphDimension.decode(plain, context: "plain")
        XCTAssertEqual(try plainDimension.resolve(screen: 257, parameters: [:]), 64)
        XCTAssertEqual(try plainDimension.resolve(screen: 257, parameters: ["size": 16]), 16)
        let squared = GraphValue.object([
            GraphField(name: "param", value: .string("size")),
            GraphField(name: "power", value: .number(2)),
            GraphField(name: "default", value: .number(4096))
        ])
        let squaredDimension = try GraphDimension.decode(squared, context: "squared")
        XCTAssertEqual(try squaredDimension.resolve(screen: 257, parameters: [:]), 4096)
        XCTAssertEqual(try squaredDimension.resolve(screen: 257, parameters: ["size": 16]), 256)
    }

    func testMalformedTextureDimensionDoesNotCoerceToFallback() throws {
        let malformed = GraphValue.object([
            GraphField(name: "param", value: .string("size")),
            GraphField(name: "power", value: .string("two"))
        ])
        XCTAssertThrowsError(try GraphDimension.decode(malformed, context: "bad"))
    }

    func testSourceExportedComputeAndMRTGraphsKeepPassOrderAndFormats() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let compute = try RenderGraph(exportedCaseData:
            Data(contentsOf: root.appendingPathComponent(".build/reference/cases/computeFilter.json")))
        XCTAssertEqual(compute.passes.count, 3)
        XCTAssertEqual(compute.programs[compute.passes[1].program]?.stage, .compute)
        XCTAssertEqual(compute.passes[1].outputs.first?.value.stringValue, "node_1_out")
        let blur = try RenderGraph(exportedCaseData:
            Data(contentsOf: root.appendingPathComponent(".build/reference/cases/multipassBlur.json")))
        XCTAssertEqual(blur.passes.count, 4)
        XCTAssertEqual(blur.textures.first(where: { $0.key == "node_1__blurTemp" })?.format, "rgba8unorm")
        let mrt = try RenderGraph(exportedCaseData:
            Data(contentsOf: root.appendingPathComponent(".build/reference/cases/mrtProbe.json")))
        XCTAssertEqual(mrt.passes.first?.outputs.map(\.key), ["first", "second"])
        XCTAssertEqual(mrt.passes[1].inputs.map(\.key), ["firstTex", "secondTex"])
    }

    func testTaggedNegativeZeroPreservesFloatSignAndOtherNumberTagsRefuse() throws {
        let decoded = try GraphValue.decode(["$type": "number", "value": "-0"])
        guard case .number(let value) = decoded else { return XCTFail("Expected tagged number") }
        XCTAssertEqual(value, 0)
        XCTAssertEqual(Float(value).bitPattern, Float(-0.0).bitPattern)
        XCTAssertThrowsError(try GraphValue.decode(["$type": "number", "value": "NaN"]))
    }

    func testComputeTargetWithNonScreenDimensionsRefusesBeforeEncoding() throws {
        let changed = try changingGraph(caseData("computeFilter")) { fields in
            try changeTexture(&fields, name: "node_1_out", field: "width", to: 128)
        }
        let graph = try RenderGraph(exportedCaseData: changed)
        XCTAssertThrowsError(try graph.validateDimensions(for: RenderSize(width: 257, height: 129)))
    }

    func testNonNumericOrVaryingScreenDivisorRefuses() throws {
        let divisor: [String: Any] = ["$type": "object", "entries": [["screenDivide", "zoom"]]]
        let nonnumeric = try changingGraph(fixture()) { fields in
            try changeTexture(&fields, name: "node_0_out", field: "width", to: divisor)
            try addUniform(&fields, pass: 0, name: "zoom", value: [
                "$type": "object", "entries": [["oscillator", "unresolved"]]
            ])
        }
        XCTAssertThrowsError(try RenderGraph(exportedCaseData: nonnumeric))
        let varying = try changingGraph(fixture()) { fields in
            try changeTexture(&fields, name: "node_0_out", field: "width", to: divisor)
            try addUniform(&fields, pass: 0, name: "zoom", value: 2)
            try addUniform(&fields, pass: 1, name: "zoom", value: 3)
        }
        XCTAssertThrowsError(try RenderGraph(exportedCaseData: varying))
    }

}
