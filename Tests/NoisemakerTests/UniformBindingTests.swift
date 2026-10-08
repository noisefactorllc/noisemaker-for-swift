import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct UniformBindingTests {
    @Test func testPackedBytesMatchUpstreamWriter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"].map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/reference")
        let corpus = try requireValue(JSONSerialization.jsonObject(with: Data(contentsOf: reference.appendingPathComponent("uniforms.json"))) as? [String: Any])
        let lock = try requireValue(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("parity/reference.json"))) as? [String: String])
        expectEqual(corpus["reference"] as? [String: String], lock)
        let cases = try requireValue(corpus["cases"] as? [[String: Any]])
        expectEqual(cases.count, 4)
        for item in cases {
            let name = try requireValue(item["name"] as? String)
            let slots = try requireValue(item["slots"] as? Int)
            let layout = try GraphValue.decode(requireValue(item["layout"]))
            let fields = try requireValue(GraphValue.decode(requireValue(item["values"])).objectFields)
            let wgsl = "struct Uniforms { data: array<vec4<f32>, \(slots)>, }"
            let plan = try UniformPlan.parse(type: "Uniforms", wgsl: wgsl, layout: layout, program: name)
            let pass = GraphPass(id: name, program: name, raw: .object([]), inputs: [], outputs: [], uniforms: fields, entryPoint: "main", repeatCount: 1)
            let actual = try plan.encode(name: "uniforms", pass: pass,
                frame: FrameState(time: 0.25, delta: 0, frameIndex: 7), size: RenderSize(width: 257, height: 129))
            let expected = try requireValue(item["bytes"] as? [UInt8])
            expectEqual(Array(actual), expected, name)
        }
    }

    @Test func testRejectsOversizedAndNoncontiguousPackedLayoutsBeforeEncoding() throws {
        let layout = GraphValue.object([GraphField(name: "value", value: .object([
            GraphField(name: "slot", value: .number(0)), GraphField(name: "components", value: .string("xz"))]))])
        expectThrows(try UniformPlan.parse(type: "Uniforms",
            wgsl: "struct Uniforms { data: array<vec4<f32>, 1>, }", layout: layout, program: "bad-swizzle"))
        let safe = GraphValue.object([GraphField(name: "value", value: .object([
            GraphField(name: "slot", value: .number(0)), GraphField(name: "components", value: .string("x"))]))])
        expectThrows(try UniformPlan.parse(type: "Uniforms",
            wgsl: "struct Uniforms { data: array<vec4<f32>, 1000000>, }", layout: safe, program: "oversized"))
    }

    @Test func testAuthoredLayoutCanExtendFeedbackShaderMinimum() throws {
        // MNCA shares a seven-slot authored layout across its feedback and
        // display passes, while the feedback WGSL declares only six slots.
        let layout = GraphValue.object([
            GraphField(name: "tileOffset", value: .object([
                GraphField(name: "slot", value: .number(6)),
                GraphField(name: "components", value: .string("xy"))])),
            GraphField(name: "fullResolution", value: .object([
                GraphField(name: "slot", value: .number(6)),
                GraphField(name: "components", value: .string("zw"))]))
        ])
        let wgsl = "struct Uniforms { data: array<vec4<f32>, 6>, }"
        let plan = try UniformPlan.parse(type: "Uniforms", wgsl: wgsl,
            layout: layout, program: "mncaFb")
        guard case .packed(let count, _) = plan else {
            Issue.record("explicit MNCA layout was not packed")
            return
        }
        expectEqual(count, 7)
        let pass = GraphPass(id: "mncaFb", program: "mncaFb", raw: .object([]),
            inputs: [], outputs: [], uniforms: [], entryPoint: "main", repeatCount: 1)
        let bytes = try plan.encode(name: "uniforms", pass: pass, frame: .zero,
            size: RenderSize(width: 257, height: 129))
        expectEqual(bytes.count, 112)
        expectEqual(Array(bytes[96..<104]), [UInt8](repeating: 0, count: 8))
        let widthBytes = withUnsafeBytes(of: Float(257).bitPattern.littleEndian) { Array($0) }
        let heightBytes = withUnsafeBytes(of: Float(129).bitPattern.littleEndian) { Array($0) }
        expectEqual(Array(bytes[104..<108]), widthBytes)
        expectEqual(Array(bytes[108..<112]), heightBytes)

        let largerMinimum = try UniformPlan.parse(type: "Uniforms",
            wgsl: "struct Uniforms { data: array<vec4<f32>, 8>, }",
            layout: layout, program: "mncaFb")
        guard case .packed(let largerCount, _) = largerMinimum else {
            Issue.record("explicit layout with a larger shader minimum was not packed")
            return
        }
        expectEqual(largerCount, 8)
        expectEqual(try largerMinimum.encode(name: "uniforms", pass: pass, frame: .zero,
            size: RenderSize(width: 257, height: 129)).count, 128)
    }

    @Test func testAuthoredLayoutRejectsSlotBeyondUniformBufferLimit() throws {
        let layout = GraphValue.object([GraphField(name: "value", value: .object([
            GraphField(name: "slot", value: .number(4_096)),
            GraphField(name: "components", value: .string("x"))]))])
        expectThrows(try UniformPlan.parse(type: "Uniforms",
            wgsl: "struct Uniforms { data: array<vec4<f32>, 1>, }",
            layout: layout, program: "oversized-slot"))
    }
}
