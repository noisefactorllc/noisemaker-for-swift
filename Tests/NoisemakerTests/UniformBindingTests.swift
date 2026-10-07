import Foundation
import XCTest
@testable import Noisemaker

final class UniformBindingTests: XCTestCase {
    func testPackedBytesMatchUpstreamWriter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"].map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/reference")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reference.appendingPathComponent("uniforms.json"))) as? [String: Any])
        let lock = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("parity/reference.json"))) as? [String: String])
        XCTAssertEqual(corpus["reference"] as? [String: String], lock)
        let cases = try XCTUnwrap(corpus["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 4)
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let slots = try XCTUnwrap(item["slots"] as? Int)
            let layout = try GraphValue.decode(XCTUnwrap(item["layout"]))
            let fields = try XCTUnwrap(GraphValue.decode(XCTUnwrap(item["values"])).objectFields)
            let wgsl = "struct Uniforms { data: array<vec4<f32>, \(slots)>, }"
            let plan = try UniformPlan.parse(type: "Uniforms", wgsl: wgsl, layout: layout, program: name)
            let pass = GraphPass(id: name, program: name, raw: .object([]), inputs: [], outputs: [], uniforms: fields, entryPoint: "main")
            let actual = try plan.encode(name: "uniforms", pass: pass,
                frame: FrameState(time: 0.25, delta: 0, frameIndex: 7), size: RenderSize(width: 257, height: 129))
            let expected = try XCTUnwrap(item["bytes"] as? [UInt8])
            XCTAssertEqual(Array(actual), expected, name)
        }
    }

    func testRejectsOversizedAndNoncontiguousPackedLayoutsBeforeEncoding() throws {
        let layout = GraphValue.object([GraphField(name: "value", value: .object([
            GraphField(name: "slot", value: .number(0)), GraphField(name: "components", value: .string("xz"))]))])
        XCTAssertThrowsError(try UniformPlan.parse(type: "Uniforms",
            wgsl: "struct Uniforms { data: array<vec4<f32>, 1>, }", layout: layout, program: "bad-swizzle"))
        let safe = GraphValue.object([GraphField(name: "value", value: .object([
            GraphField(name: "slot", value: .number(0)), GraphField(name: "components", value: .string("x"))]))])
        XCTAssertThrowsError(try UniformPlan.parse(type: "Uniforms",
            wgsl: "struct Uniforms { data: array<vec4<f32>, 1000000>, }", layout: safe, program: "oversized"))
    }
}
