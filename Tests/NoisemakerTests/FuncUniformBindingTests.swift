import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct FuncUniformBindingTests {
    private let size = try! RenderSize(width: 1, height: 1)

    private func pass(_ value: GraphValue) -> GraphPass {
        GraphPass(id: "sourceFunc", program: "test", raw: .object([]),
            inputs: [], outputs: [],
            uniforms: [GraphField(name: "seed", value: value)],
            entryPoint: "main", repeatCount: 1)
    }

    private var sourceFunc: GraphValue {
        .object([
            GraphField(name: "fn", value: .tagged("function", [
                GraphField(name: "source", value: .string("(state) => state.time"))
            ])),
            GraphField(name: "min", value: .number(1)),
            GraphField(name: "max", value: .number(100))
        ])
    }

    @Test func testSourceFunctionWrapperLeavesDirectStructAndPackedBytesZero() throws {
        let source = pass(sourceFunc)
        let direct = try UniformPlan.direct(.f32).encode(name: "seed", pass: source,
            frame: .zero, size: size)
        expectEqual(Array(direct), [UInt8](repeating: 0, count: 4))

        let structure = try UniformPlan.structure([
            UniformField(name: "seed", type: .vector(.f32, count: 3))
        ]).encode(name: "u", pass: source, frame: .zero, size: size)
        expectEqual(Array(structure), [UInt8](repeating: 0, count: 16))

        let packed = try UniformPlan.packed(count: 1, [
            PackedUniformEntry(name: "seed", slot: 0, components: [0])
        ]).encode(name: "u", pass: source, frame: .zero, size: size)
        expectEqual(Array(packed), [UInt8](repeating: 0, count: 16))
    }

    @Test func testArbitraryObjectUsesSourceDirectDefault() throws {
        let source = pass(.object([GraphField(name: "arbitrary", value: .number(1))]))
        let direct = try UniformPlan.direct(.f32).encode(name: "seed", pass: source,
            frame: .zero, size: size)
        expectEqual(Array(direct), [UInt8](repeating: 0, count: 4))
    }
}
