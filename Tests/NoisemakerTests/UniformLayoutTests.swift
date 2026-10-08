import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct UniformLayoutTests {
    @Test func testMixedWGSLLayoutAndColumnMajorBytes() throws {
        let layout = try UniformLayout(fields: [
            UniformField(name: "gain", type: .f32),
            UniformField(name: "direction", type: .vector(.f32, count: 3)),
            UniformField(name: "enabled", type: .u32),
            UniformField(name: "basis", type: .matrix(columns: 3, rows: 3)),
            UniformField(name: "samples", type: .array(.vector(.f32, count: 2), count: 2)),
            UniformField(name: "count", type: .i32),
        ])
        expectEqual(layout.fields.map(\.offset), [0, 16, 28, 32, 80, 112])
        expectEqual(layout.alignment, 16)
        expectEqual(layout.byteCount, 128)
        let data = try UniformWriter.encode(values: ["gain": [0.25], "direction": [1, 2, 3], "enabled": [1],
            "basis": [1, 2, 3, 4, 5, 6, 7, 8, 9], "samples": [0.2, 0.4, 0.6, 0.8], "count": [-7]], layout: layout)
        expectEqual(Array(data[0..<4]), [0, 0, 128, 62])
        expectEqual(Array(data[4..<16]), Array(repeating: 0, count: 12))
        expectEqual(Array(data[28..<32]), [1, 0, 0, 0])
        expectEqual(Array(data[44..<48]), [0, 0, 0, 0])
        expectEqual(Array(data[48..<52]), [0, 0, 128, 64])
        expectEqual(Array(data[112..<116]), [249, 255, 255, 255])
        expectEqual(Array(data[116..<128]), Array(repeating: 0, count: 12))
    }

    @Test func testRejectsTruncationOverflowAndIncompleteValues() throws {
        let layout = try UniformLayout(fields: [UniformField(name: "value", type: .u32)])
        for value in [Double.nan, .infinity, -1, 0.5, Double(UInt32.max) + 1] {
            expectThrows(try UniformWriter.encode(values: ["value": [value]], layout: layout))
        }
        expectThrows(try UniformWriter.encode(values: [:], layout: layout))
        expectThrows(try UniformWriter.encode(values: ["value": [1, 2]], layout: layout))
        expectThrows(try UniformWriter.encode(values: ["value": [1], "unknown": [2]], layout: layout))
        expectThrows(try UniformLayout(fields: [UniformField(name: "large", type: .array(.f32, count: Int.max))]))
        expectThrows(try UniformLayout(fields: [UniformField(name: "bad", type: .vector(.f32, count: 5))]))
        expectThrows(try UniformLayout(fields: [UniformField(name: "x", type: .f32), UniformField(name: "x", type: .f32)]))
        let float = try UniformLayout(fields: [UniformField(name: "value", type: .f32)])
        expectThrows(try UniformWriter.encode(values: ["value": [Double.greatestFiniteMagnitude]], layout: float))
    }

    @Test func testScalarArraysNestedStructuresAndTwoRowMatrixStride() throws {
        let nested = UniformType.structure([UniformField(name: "a", type: .f32)])
        let layout = try UniformLayout(fields: [UniformField(name: "items", type: .array(nested, count: 2)),
            UniformField(name: "matrix", type: .matrix(columns: 3, rows: 2))])
        expectEqual(layout.fields.map(\.offset), [0, 32])
        expectEqual(layout.byteCount, 64)
        let data = try UniformWriter.encode(values: ["items": [1, 2], "matrix": [1, 2, 3, 4, 5, 6]], layout: layout)
        expectEqual(Array(data[16..<20]), [0, 0, 0, 64])
        expectEqual(Array(data[40..<44]), [0, 0, 64, 64])
    }
}
