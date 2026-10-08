import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct AudioBufferBindingTests {
    private func encode(_ name: String, audio: AudioInputSnapshot? = nil, explicit: [Float]? = nil) throws -> Data {
        let plan = try UniformPlan.parse(type: "array<vec4<f32>,32>", wgsl: "", layout: nil, program: name)
        let pass = GraphPass(id: name, program: name, raw: .object([]), inputs: [], outputs: [],
            uniforms: explicit.map { [GraphField(name: name, value: .array($0.map { .number(Double($0)) }))] } ?? [], entryPoint: "main", repeatCount: 1)
        return try plan.encode(name: name, pass: pass,
            frame: FrameState(time: 0, delta: 0, frameIndex: 0, inputs: AutomationInputs(audio: audio)),
            size: RenderSize(width: 33, height: 17))
    }
    @Test func hostAudioSamplesBindAndSilenceDefaultsRemainDistinct() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var audio = AudioInputSnapshot()
        for (name, file) in [("audioWaveform", "waveform"), ("audioSpectrum", "spectrum")] {
            let expected = try Data(contentsOf: root.appendingPathComponent("parity/inputs/audio-v1.\(file).f32le"))
            let values = stride(from: 0, to: expected.count, by: 4).map { index -> Float in
                let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(expected[index+$1]) << ($1 * 8) }
                return Float(bitPattern: bits)
            }
            if name == "audioWaveform" { audio.waveform = values } else { audio.spectrum = values }
            expectEqual(try encode(name, audio: audio), expected)
            expectEqual(try encode(name, explicit: values), expected)
        }
        expectEqual(try encode("audioSpectrum"), Data(repeating: 0, count: 512))
        let quiet = Data((0..<128).flatMap { _ in [UInt8(0), 0, 0, 0x3f] })
        expectEqual(try encode("audioWaveform"), quiet)
        expectThrows(try encode("audioWaveform", audio: AudioInputSnapshot(waveform: [0.5])))
    }
    @Test func sourceShorthandVectorsAndMatricesHaveExpectedLayout() throws {
        let wgsl = "struct Uniforms { position: vec2f, index: vec2u, axis: vec3i, _pad: f32, transform: mat3x3f, } var<uniform> u: Uniforms; fn main() { let p = u.position; }"
        let plan = try UniformPlan.parse(type: "Uniforms", wgsl: wgsl, layout: nil, program: "aliases")
        guard case .structure(let fields) = plan else { Issue.record("expected struct"); return }
        let layout = try UniformLayout(fields: fields)
        expectEqual(layout.fields.map(\.offset), [0,8,16,28,32])
        expectEqual(layout.byteCount, 80)
        expectEqual(fields[0].type, .vector(.f32, count: 2))
        expectEqual(fields[1].type, .vector(.u32, count: 2))
        expectEqual(fields[2].type, .vector(.i32, count: 3))
        expectEqual(fields[4].type, .matrix(columns: 3, rows: 3))
    }
}
