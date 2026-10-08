import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct HostUniformBindingTests {
    private let size = try! RenderSize(width: 16, height: 16)

    private func pass(node: String, authored: GraphValue = .undefined) -> GraphPass {
        GraphPass(id: "\(node)_pass_0", program: "media", raw: .object([
            GraphField(name: "nodeId", value: .string(node)),
            GraphField(name: "effectKey", value: .string("synth.media"))
        ]), inputs: [], outputs: [],
        uniforms: [GraphField(name: "imageSize", value: authored)],
        entryPoint: "main", repeatCount: 1)
    }

    private func value(_ pass: GraphPass, frame: FrameState) throws -> Float {
        let encoded = try UniformPlan.direct(.f32).encode(name: "imageSize", pass: pass,
            frame: frame, size: size)
        return encoded.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    @Test func testNodeScopedHookFallbackKeepsDuplicateEffectsIsolated() throws {
        let frame = FrameState(time: 0, delta: 0, frameIndex: 0, hostUniforms: [
            "node_0": ["imageSize": .number(48)],
            "node_1": ["imageSize": .number(96)]
        ])
        expectEqual(try value(pass(node: "node_0"), frame: frame), 48)
        expectEqual(try value(pass(node: "node_1"), frame: frame), 96)
        expectEqual(try value(pass(node: "node_2"), frame: frame), 0)
    }

    @Test func testAuthoredValueWinsOverHookFallback() throws {
        let frame = FrameState(time: 0, delta: 0, frameIndex: 0,
            hostUniforms: ["node_0": ["imageSize": .number(96)]])
        expectEqual(try value(pass(node: "node_0", authored: .number(48)), frame: frame), 48)
    }
}
