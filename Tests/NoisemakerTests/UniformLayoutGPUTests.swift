import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct UniformLayoutGPUTests {
    @Test func testShaderReadsMixedUniformOffsetsAndPadding() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Uniform ABI qualification requires native Metal")
        let layout = try UniformLayout(fields: [
            UniformField(name: "gain", type: .f32),
            UniformField(name: "direction", type: .vector(.f32, count: 3)),
            UniformField(name: "enabled", type: .u32),
            UniformField(name: "basis", type: .matrix(columns: 3, rows: 3)),
            UniformField(name: "samples", type: .array(.vector(.f32, count: 2), count: 2)),
            UniformField(name: "count", type: .i32),
        ])
        let expected: [Float] = [0.25, 1, 2, 3, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0.2, 0.4, 0.6, 0.8, -7]
        let data = try UniformWriter.encode(values: ["gain": [0.25], "direction": [1, 2, 3], "enabled": [1],
            "basis": [1, 2, 3, 4, 5, 6, 7, 8, 9], "samples": [0.2, 0.4, 0.6, 0.8], "count": [-7]], layout: layout)
        let wgsl = """
        struct Sample { @size(16) value: vec2<f32>, }
        struct Uniforms {
            gain: f32,
            direction: vec3<f32>,
            enabled: u32,
            basis: mat3x3<f32>,
            samples: array<Sample, 2>,
            count: i32,
        }
        @group(0) @binding(0) var<uniform> u: Uniforms;
        @group(0) @binding(1) var<storage, read_write> out: array<f32, 19>;
        @compute @workgroup_size(1) fn main() {
            out[0] = u.gain;
            out[1] = u.direction.x; out[2] = u.direction.y; out[3] = u.direction.z;
            out[4] = f32(u.enabled);
            out[5] = u.basis[0][0]; out[6] = u.basis[0][1]; out[7] = u.basis[0][2];
            out[8] = u.basis[1][0]; out[9] = u.basis[1][1]; out[10] = u.basis[1][2];
            out[11] = u.basis[2][0]; out[12] = u.basis[2][1]; out[13] = u.basis[2][2];
            out[14] = u.samples[0].value.x; out[15] = u.samples[0].value.y;
            out[16] = u.samples[1].value.x; out[17] = u.samples[1].value.y;
            out[18] = f32(u.count);
        }
        """
        let translation = try ShaderTranslator().translate(wgsl: wgsl, entryPoint: "main", stage: .compute,
            bindings: [TintBinding(group: 0, binding: 0, kind: .uniform, slot: 6), TintBinding(group: 0, binding: 1, kind: .storage, slot: 7)])
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: translation.source, options: options)
        let function = try requireValue(library.makeFunction(name: translation.mslEntryPoint))
        let pipeline = try device.makeComputePipelineState(function: function)
        let uniforms = try data.withUnsafeBytes { bytes in
            try requireValue(device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared))
        }
        let output = try requireValue(device.makeBuffer(length: expected.count * 4, options: .storageModeShared))
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let encoder = try requireValue(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(uniforms, offset: 0, index: 6)
        encoder.setBuffer(output, offset: 0, index: 7)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        let actual = Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: Float.self), count: expected.count))
        expectEqual(actual, expected)
    }
}
