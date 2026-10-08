import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct ParameterUpdatesTests {
    private func oracle() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("parity/parameter-updates.json"))
        return try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        return try requireValue(String(data: data, encoding: .utf8))
    }

    @Test func sourcePerStepUniformUpdatesRemainIsolatedAndExact() throws {
        let root = try oracle()
        let cases = try requireValue(root["cases"] as? [[String: Any]])
        let registry = try EffectRegistry.bundled()
        let compiler = NoisemakerCompiler(registry: registry)
        for fixture in cases {
            let id = try requireValue(fixture["id"] as? String)
            let source = try requireValue(fixture["source"] as? String)
            let before = try compiler.compile(source: source)
            let original = try canonical(before.raw.taggedValue())
            let updates = try GraphValue.decode(requireValue(fixture["updates"]))
            var updated = before
            for step in updates.objectFields ?? [] {
                let index = try requireValue(Int(step.name.dropFirst("step_".count)))
                updated = try updated.updatedParameters(stepIndex: index,
                    values: step.value.objectFields ?? [], registry: registry)
            }
            let expected = try requireValue((fixture["after"] as? [String: Any])?["passes"] as? [[String: Any]])
            expectEqual(updated.passes.count, expected.count)
            for (pass, reference) in zip(updated.passes, expected) {
                expectEqual(pass.id, reference["id"] as? String)
                let actual = try canonical(pass.raw.field("uniforms")?.taggedValue() ?? [:])
                let wanted = try canonical(requireValue(reference["uniforms"]))
                expectEqual(actual, wanted, "\(id): \(pass.id)")
            }
            expectEqual(try canonical(before.raw.taggedValue()), original,
                        "\(id): original graph changed")
        }
    }

    @Test func scopedUpdatesResolvePinnedTextureDimensions() throws {
        let cases = try requireValue(oracle()["cases"] as? [[String: Any]])
        let registry = try EffectRegistry.bundled()
        let compiler = NoisemakerCompiler(registry: registry)
        for fixture in cases {
            let id = try requireValue(fixture["id"] as? String)
            guard ["inherited-volume", "scoped-zoom", "node-state-size"].contains(id) else { continue }
            var graph = try compiler.compile(source: requireValue(fixture["source"] as? String))
            let updates = try GraphValue.decode(requireValue(fixture["updates"]))
            for step in updates.objectFields ?? [] {
                let index = try requireValue(Int(step.name.dropFirst("step_".count)))
                graph = try graph.updatedParameters(stepIndex: index,
                    values: step.value.objectFields ?? [], registry: registry)
            }
            let before = try GraphValue.decode(requireValue((fixture["before"] as? [String: Any])?["textures"]))
            let after = try GraphValue.decode(requireValue((fixture["after"] as? [String: Any])?["textures"]))
            var changed = 0
            for item in after.mapEntries ?? [] {
                guard let name = item.key.stringValue,
                      let original = before.mapEntries?.first(where: { $0.key.stringValue == name })?.value,
                      try canonical(original.taggedValue()) != canonical(item.value.taggedValue()) else {
                    continue
                }
                changed += 1
                let base = name.hasSuffix("_read") ? String(name.dropLast(5))
                    : name.hasSuffix("_write") ? String(name.dropLast(6)) : name
                let texture = try requireValue(graph.textures.first(where: { $0.key == base }),
                                               "\(id): \(name) graph texture")
                let width = try requireValue(item.value.field("width")?.numberValue)
                let height = try requireValue(item.value.field("height")?.numberValue)
                expectEqual(try texture.width.resolve(screen: 256, parameters: graph.dimensionParameters),
                            Int(width), "\(id): \(name) width")
                expectEqual(try texture.height.resolve(screen: 256, parameters: graph.dimensionParameters),
                            Int(height), "\(id): \(name) height")
            }
            expectTrue(changed > 0, "\(id) changed no source textures")
        }
    }

    @Test func rejectedUpdateKeepsOriginalGraphAndRequiresDefineRecompile() throws {
        let registry = try EffectRegistry.bundled()
        let graph = try NoisemakerCompiler(registry: registry).compile(
            source: "search synth\nsolid(color: #123456).write(o0)\nrender(o0)\n")
        let before = try canonical(graph.raw.taggedValue())
        expectThrows(try graph.updatedParameter(stepIndex: 0, name: "missing",
                                                value: .number(1), registry: registry))
        expectThrows(try graph.updatedParameter(stepIndex: 0, name: "color",
                                                value: .string("#nothex"), registry: registry))
        expectThrows(try graph.updatedParameters(stepIndex: 0, values: [
            GraphField(name: "color", value: .string("#abcdef")),
            GraphField(name: "missing", value: .number(1))
        ], registry: registry))
        expectEqual(try canonical(graph.raw.taggedValue()), before)

        let defineGraph = try NoisemakerCompiler(registry: registry).compile(
            source: "search synth, filter\nsolid().median().write(o0)\nrender(o0)\n")
        let defineBefore = try canonical(defineGraph.raw.taggedValue())
        expectThrows(try defineGraph.updatedParameter(stepIndex: 1, name: "radius",
                                                      value: .number(2), registry: registry)) { error in
            expectTrue(String(describing: error).contains("recompile the DSL"))
        }
        expectEqual(try canonical(defineGraph.raw.taggedValue()), defineBefore)
    }

    @Test func sourcePaletteRefusalsLeaveImmutableGraphUntouched() throws {
        let refusals = try requireValue(oracle()["refusals"] as? [[String: Any]])
        expectEqual(refusals.count, 5)
        let registry = try EffectRegistry.bundled()
        let compiler = NoisemakerCompiler(registry: registry)
        for fixture in refusals {
            let id = try requireValue(fixture["id"] as? String)
            let source = try requireValue(fixture["source"] as? String)
            let expectedError = try requireValue(fixture["error"] as? [String: String])
            expectEqual(expectedError["name"], "TypeError", id)
            let graph = try compiler.compile(source: source)
            let original = try canonical(graph.raw.taggedValue())
            let updates = try GraphValue.decode(requireValue(fixture["updates"]))
            let step = try requireValue(updates.objectFields?.first)
            let index = try requireValue(Int(step.name.dropFirst("step_".count)))
            expectThrows(try graph.updatedParameters(stepIndex: index,
                values: step.value.objectFields ?? [], registry: registry))
            expectEqual(try canonical(graph.raw.taggedValue()), original, id)
        }

        let source = try requireValue(refusals.first?["source"] as? String)
        let graph = try compiler.compile(source: source)
        let original = try canonical(graph.raw.taggedValue())
        expectThrows(try graph.updatedParameters(stepIndex: 0, values: [
            GraphField(name: "paletteOffset", value: .array([
                .number(0.1), .number(0.2), .number(0.3)])),
            GraphField(name: "palette", value: .number(1.5))
        ], registry: registry))
        expectEqual(try canonical(graph.raw.taggedValue()), original,
                    "failed palette expansion must not publish an earlier batch write")
    }

    @Test func absentPaletteUniformSkipsSourceExpansion() throws {
        let registry = try EffectRegistry.bundled()
        let compiler = NoisemakerCompiler(registry: registry)
        let cases = try requireValue(oracle()["cases"] as? [[String: Any]])
        let source = try requireValue(cases.first(where: {
            ($0["id"] as? String) == "palette-post-write"
        })?["source"] as? String)
        let graph = try compiler.compile(source: source)
        var passes = try requireValue(graph.raw.field("passes")?.arrayValue)
        let index = try requireValue(passes.firstIndex(where: {
            $0.field("effectKey")?.stringValue == "classicNoisedeck.cellNoise"
        }))
        var pass = OrderedObject(passes[index])
        var uniforms = OrderedObject(pass["uniforms"])
        uniforms["palette"] = nil
        pass["uniforms"] = uniforms.value
        passes[index] = pass.value
        var raw = OrderedObject(graph.raw)
        raw["passes"] = .array(passes)
        let withoutPalette = try RenderGraph(exportedCaseData:
            compiler.makeRenderGraphInput(raw.value))
        let updated = try withoutPalette.updatedParameter(stepIndex: 0, name: "palette",
            value: .number(1.5), registry: registry)
        expectEqual(try canonical(updated.raw.taggedValue()),
                    try canonical(withoutPalette.raw.taggedValue()))
    }
}
