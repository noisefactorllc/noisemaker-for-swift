import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct FullOverwriteProofTests {
    private func solidGraph() throws -> RenderGraph {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try RenderGraph(exportedCaseData: Data(contentsOf:
            root.appendingPathComponent(".build/reference/cases/solid.json")))
    }

    private func replacingSource(_ source: String, in program: GraphProgram) -> GraphProgram {
        GraphProgram(id: program.id, raw: program.raw, resolvedWGSL: source,
            fragmentEntryPoint: program.fragmentEntryPoint,
            vertexEntryPoint: program.vertexEntryPoint, stage: program.stage,
            defaultEntryPoint: program.defaultEntryPoint)
    }

    @Test func directColorReturnProvesFullOverwrite() throws {
        let graph = try solidGraph()
        let pass = try requireValue(graph.passes.first)
        let program = try requireValue(graph.programs[pass.program])
        expectTrue(ShaderCompiler.provesFullOverwrite(pass: pass, program: program))
        expectTrue(graph.persistentTextureNames.contains("node_0_out"),
            "Without checking the supplied fallback vertex, the decoded graph must retain load history")
        let qualified = graph.omittingProvenFullOverwrites(knownFullScreenVertex: true)
        expectFalse(qualified.persistentTextureNames.contains("node_0_out"))
        let restored = qualified.omittingProvenFullOverwrites(knownFullScreenVertex: false)
        expectTrue(restored.persistentTextureNames.contains("node_0_out"),
            "A graph reused with a custom vertex must regain conservative history")
    }

    @Test func commentedFakeSignatureCannotProveStructOutput() throws {
        let graph = try solidGraph()
        let pass = try requireValue(graph.passes.first)
        let original = try requireValue(graph.programs[pass.program])
        let source = """
            /* @fragment fn main() -> @location(0) vec4<f32> { return vec4<f32>(1.0); } */
            struct Color { @location(0) value: vec4<f32>, };
            @fragment fn main() -> Color { return Color(vec4<f32>(1.0)); }
            """
        expectFalse(ShaderCompiler.provesFullOverwrite(pass: pass,
            program: replacingSource(source, in: original)))
    }

    @Test func discardAndSampleMaskStayRetained() throws {
        let graph = try solidGraph()
        let pass = try requireValue(graph.passes.first)
        let original = try requireValue(graph.programs[pass.program])
        let discarding = original.resolvedWGSL.replacingOccurrences(of:
            "return vec4<f32>(color * alpha, alpha);",
            with: "if (alpha < 0.5) { discard; } return vec4<f32>(color * alpha, alpha);")
        expectFalse(ShaderCompiler.provesFullOverwrite(pass: pass,
            program: replacingSource(discarding, in: original)))
        let masking = original.resolvedWGSL + "\n@builtin(sample_mask)\n"
        expectFalse(ShaderCompiler.provesFullOverwrite(pass: pass,
            program: replacingSource(masking, in: original)))
    }

}

@Suite(.serialized)
struct FullOverwriteGPUTests {
    private func solidGraph() throws -> RenderGraph {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try RenderGraph(exportedCaseData: Data(contentsOf:
            root.appendingPathComponent(".build/reference/cases/solid.json")))
    }

    @Test func differentFallbackVertexKeepsSinglePendingHistory() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let registry = try EffectRegistry.bundled()
        let defaultSource = try requireValue(registry.defaultVertex.field("wgsl")?.stringValue)
        let customSource = defaultSource.replacingOccurrences(of:
            "vec2<f32>(3.0, -1.0)", with: "vec2<f32>(1.0, -1.0)")
        expectFalse(customSource == defaultSource)
        let optimized = try NoisemakerRenderer(device: device, graph: solidGraph(),
            size: RenderSize(width: 17, height: 9), defaultVertexWGSL: defaultSource,
            vertexEntryPoint: "vs_main", registry: registry)
        expectFalse(optimized.graph.persistentTextureNames.contains("node_0_out"))
        let renderer = try NoisemakerRenderer(device: device, graph: optimized.graph,
            size: RenderSize(width: 17, height: 9), defaultVertexWGSL: customSource,
            vertexEntryPoint: "vs_main", registry: registry)
        expectTrue(renderer.graph.persistentTextureNames.contains("node_0_out"))
        let queue = try requireValue(device.makeCommandQueue())
        let event = try requireValue(device.makeSharedEvent())
        let first = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: first)
        first.encodeWaitForEvent(event, value: 1)
        first.commit()
        defer { event.signaledValue = 1 }
        expectThrows(try renderer.encode(into: requireValue(queue.makeCommandBuffer()))) { error in
            expectTrue(String(describing: error).contains("feedback frame"))
        }
        event.signaledValue = 1
        first.waitUntilCompleted()
        expectEqual(first.status, .completed)
        withExtendedLifetime(lease) {}
    }
}
