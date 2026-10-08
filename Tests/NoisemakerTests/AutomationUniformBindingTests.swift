import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct AutomationUniformBindingTests {
    private func scalar(_ data: Data) -> Float {
        let bits = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return Float(bitPattern: UInt32(littleEndian: bits))
    }

    @Test func frameInputsAndParameterRangeReachUniformBytes() throws {
        let midi: GraphValue = .object([
            GraphField(name: "type", value: .string("Midi")),
            GraphField(name: "mode", value: .number(5)),
            GraphField(name: "channel", value: .number(1)),
            GraphField(name: "cc", value: .number(1)),
            GraphField(name: "min", value: .number(0)),
            GraphField(name: "max", value: .number(1)),
            GraphField(name: "sensitivity", value: .number(1))
        ])
        let spec: GraphValue = .object([
            GraphField(name: "min", value: .number(10)),
            GraphField(name: "max", value: .number(20))
        ])
        let pass = GraphPass(id: "automated", program: "test", raw: .object([
            GraphField(name: "uniformSpecs", value: .object([
                GraphField(name: "gain", value: spec)
            ]))
        ]), inputs: [], outputs: [], uniforms: [GraphField(name: "gain", value: midi)],
            entryPoint: "main", repeatCount: 1)
        let plan = UniformPlan.direct(.f32)
        let size = try RenderSize(width: 64, height: 48)
        let empty = try plan.encode(name: "gain", pass: pass,
            frame: FrameState(time: 0.25, delta: 0, frameIndex: 0), size: size)
        #expect(scalar(empty) == 10)
        let input = AutomationInputs(midi: MIDIInputSnapshot(aggregate:
            MIDIStateSnapshot(channels: [1: MIDIChannelSnapshot(cc: [1: 127])])))
        let active = try plan.encode(name: "gain", pass: pass,
            frame: FrameState(time: 0.25, delta: 0, frameIndex: 0, inputs: input), size: size)
        #expect(scalar(active) == 20)
    }
}
