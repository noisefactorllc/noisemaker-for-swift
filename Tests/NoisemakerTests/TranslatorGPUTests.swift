import Foundation
import Metal
import Testing
@testable import Noisemaker

// Task-1 feasibility only: these are native shader/ABI probes, not graph parity.
@Suite(.serialized)
struct TranslatorGPUTests {
    private func device() throws -> MTLDevice {
        try requireValue(MTLCreateSystemDefaultDevice(), "Run on a native Metal host; GPU absence is a failure, not a skipped qualification")
    }

    private func fixture(_ path: String) throws -> [String: Any] {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"]
            ?? package.appendingPathComponent(".build/reference").path
        let lock = try requireValue(JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("parity/reference.json"))) as? [String: String])
        let manifest = try requireValue(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent("source-manifest.json"))) as? [String: Any])
        guard manifest["commit"] as? String == lock["commit"],
              manifest["repository"] as? String == lock["repository"] else {
            throw NSError(domain: "NoisemakerProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Export does not match the authority lock"])
        }
        return try requireValue(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(path))) as? [String: Any])
    }

    private func program(_ name: String, id: String) throws -> String {
        let programs = try requireValue(try fixture("cases/\(name).json")["programs"] as? [String: [String: Any]])
        return try requireValue(programs[id]?["resolvedWGSL"] as? String)
    }

    private func function(_ translation: TintTranslation, device: MTLDevice) throws -> MTLFunction {
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: translation.source, options: options)
        return try requireValue(library.makeFunction(name: translation.mslEntryPoint))
    }

    private func buffer<T>(_ values: [T], device: MTLDevice) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            try requireValue(device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared))
        }
    }

    private func finish(_ command: MTLCommandBuffer) throws {
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
    }

    @Test func testRepresentativeUpstreamStagesCreateMetalFunctions() throws {
        let gpu = try device()
        let translator = ShaderTranslator()
        let pattern = #"@group\(\s*(\d+)\s*\)\s*@binding\(\s*(\d+)\s*\)\s*var(?:<([^>]+)>)?\s+\w+\s*:\s*([^;]+);"#
        let regex = try NSRegularExpression(pattern: pattern)
        var compiled = 0, expected = 0
        for name in ["solid", "resourceHeavy", "compute"] {
            let exported = try fixture("cases/\(name).json")
            let programs = try requireValue(exported["programs"] as? [String: [String: Any]])
            let referenced = try requireValue(exported["referencedPrograms"] as? [String])
            expectFalse(referenced.isEmpty)
            for id in referenced {
                let spec = programs[id]!
                let wgsl = try requireValue(spec["resolvedWGSL"] as? String)
                let source = wgsl as NSString
                let matches = regex.matches(in: wgsl, range: NSRange(location: 0, length: source.length))
                expectEqual(matches.count, wgsl.components(separatedBy: "@group(").count - 1, "Every binding must be explicit: \(id)")
                var bindings: [TintBinding] = [], sizes: [TintBufferSize] = []
                var nextBuffer: UInt32 = 0, nextTexture: UInt32 = 0, nextSampler: UInt32 = 0
                for match in matches {
                    let group = try requireValue(UInt32(source.substring(with: match.range(at: 1))))
                    let binding = try requireValue(UInt32(source.substring(with: match.range(at: 2))))
                    let space = match.range(at: 3).location == NSNotFound ? "" : source.substring(with: match.range(at: 3))
                    let type = source.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let kind: TintBindingKind, slot: UInt32
                    if space == "uniform" { kind = .uniform; slot = nextBuffer; nextBuffer += 1 }
                    else if space.hasPrefix("storage") {
                        kind = .storage; slot = nextBuffer; nextBuffer += 1
                        sizes.append(TintBufferSize(group: group, binding: binding, index: UInt32(sizes.count)))
                    } else if type.hasPrefix("texture_storage_") { kind = .storageTexture; slot = nextTexture; nextTexture += 1 }
                    else if type.hasPrefix("texture_") { kind = .texture; slot = nextTexture; nextTexture += 1 }
                    else if type.hasPrefix("sampler") { kind = .sampler; slot = nextSampler; nextSampler += 1 }
                    else { recordFailure("Unknown binding \(space) \(type) in \(id)"); return }
                    bindings.append(TintBinding(group: group, binding: binding, kind: kind, slot: slot))
                }
                expectLess(nextBuffer, 30)
                let entries = try requireValue(spec["entryPoints"] as? [[String: String]])
                expectFalse(entries.isEmpty, id)
                expected += entries.count
                for entry in entries {
                    let stage: TintStage
                    switch entry["stage"] {
                    case "vertex": stage = .vertex
                    case "fragment": stage = .fragment
                    case "compute": stage = .compute
                    default: recordFailure("Unknown stage in \(id)"); return
                    }
                    let translated = try translator.translate(wgsl: wgsl, entryPoint: requireValue(entry["name"]), stage: stage,
                        bindings: bindings, bufferSizes: sizes, bufferSizesOffset: sizes.isEmpty ? nil : 0, immediateSlot: 30)
                    _ = try function(translated, device: gpu)
                    compiled += 1
                }
            }
        }
        expectEqual(compiled, expected)
        expectGreater(compiled, 0)
        print("METAL-PROBE representative-stages=\(compiled) (library compilation only)")
    }

    @Test func testSolidFragmentRendersPremultipliedFloatColor() throws {
        let gpu = try device()
        print("METAL-PROBE device=\(gpu.name) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        let translator = ShaderTranslator()
        let vertex = try fixture("default-vertex.json")
        let vertexWGSL = try requireValue(vertex["wgsl"] as? String)
        let vertexEntry = try requireValue(vertex["entryPoint"] as? String)
        let vs = try translator.translate(wgsl: vertexWGSL, entryPoint: vertexEntry, stage: .vertex)
        let fs = try translator.translate(wgsl: program("solid", id: "node_0_solid"), entryPoint: "main", stage: .fragment,
            bindings: [TintBinding(group: 0, binding: 0, kind: .uniform, slot: 3), TintBinding(group: 0, binding: 1, kind: .uniform, slot: 7)])
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try function(vs, device: gpu)
        descriptor.fragmentFunction = try function(fs, device: gpu)
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try gpu.makeRenderPipelineState(descriptor: descriptor)
        let width = 257, height = 129
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .private
        let texture = try requireValue(gpu.makeTexture(descriptor: td))
        let rowBytes = ((width * 16 + 255) / 256) * 256
        let readback = try requireValue(gpu.makeBuffer(length: rowBytes * height, options: .storageModeShared))
        let queue = try requireValue(gpu.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1)
        let encoder = try requireValue(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        let color = try buffer([Float(0.2), 0.6, 0.9, 0], device: gpu)
        let alpha = try buffer([Float(0.5)], device: gpu)
        encoder.setFragmentBuffer(color, offset: 0, index: 3)
        encoder.setFragmentBuffer(alpha, offset: 0, index: 7)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
            destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
        blit.endEncoding()
        try finish(command)
        let expected: [Float] = [0.1, 0.3, 0.45, 0.5]
        var maxError: Float = 0
        var nonFinite = 0
        for y in 0..<height {
            let row = readback.contents().advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width { for c in 0..<4 {
                let value = row[x * 4 + c]
                if value.isFinite { maxError = max(maxError, abs(value - expected[c])) }
                else { nonFinite += 1 }
            } }
        }
        expectEqual(nonFinite, 0)
        expectLess(maxError, 0.000001)
        print("METAL-PROBE solid pixels=\(width * height) maxError=\(maxError) informative=false")
    }

    @Test func testStorageArrayLengthUsesExplicitImmediateByteLengths() throws {
        let gpu = try device()
        let wgsl = """
        @group(0) @binding(0) var<storage, read> values: array<u32>;
        @group(0) @binding(1) var<storage, read_write> result: array<u32, 2>;
        @compute @workgroup_size(1) fn main() {
            result[0] = arrayLength(&values);
            result[1] = values[0];
        }
        """
        let translation = try ShaderTranslator().translate(wgsl: wgsl, entryPoint: "main", stage: .compute,
            bindings: [TintBinding(group: 0, binding: 0, kind: .storage, slot: 2),
                TintBinding(group: 0, binding: 1, kind: .storage, slot: 3)],
            bufferSizes: [TintBufferSize(group: 0, binding: 0, index: 0)], bufferSizesOffset: 16, immediateSlot: 29)
        expectTrue(translation.needsStorageBufferSizes)
        let pipeline = try gpu.makeComputePipelineState(function: function(translation, device: gpu))
        let input = try buffer([UInt32](repeating: 37, count: 16), device: gpu)
        let queue = try requireValue(gpu.makeCommandQueue())
        for count: UInt32 in [16, 5] {
            let output = try buffer([UInt32.max, UInt32.max], device: gpu)
            // Deliberate nonzero offset and nondefault slot catch layout/slot guesses.
            let immediate = try buffer([UInt32(99), 99, 99, 99, count * 4], device: gpu)
            let command = try requireValue(queue.makeCommandBuffer())
            let encoder = try requireValue(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(input, offset: 0, index: 2)
            encoder.setBuffer(output, offset: 0, index: 3)
            encoder.setBuffer(immediate, offset: 0, index: 29)
            encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.endEncoding()
            try finish(command)
            let values = output.contents().assumingMemoryBound(to: UInt32.self)
            expectEqual(values[0], count)
            expectEqual(values[1], 37)
        }
    }

    @Test func testGrainComputePreservesAsymmetricTextureWhenAlphaIsZero() throws {
        let gpu = try device()
        let width = 257, height = 129
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = Float(x) / Float(width)
            pixels[i + 1] = Float(y) / Float(height)
            pixels[i + 2] = Float((x * 3 + y * 7) % 29) / 29
            pixels[i + 3] = Float((x + y) % 5) / 4
        } }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        td.usage = [.shaderRead]
        td.storageMode = .shared
        let input = try requireValue(gpu.makeTexture(descriptor: td))
        pixels.withUnsafeBytes { bytes in input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: bytes.baseAddress!, bytesPerRow: width * 16) }
        let output = try buffer([Float](repeating: -99, count: pixels.count), device: gpu)
        let uniforms = try buffer([Float(width), Float(height), 4, 0, 0.25, 0, 1, 0, 0, 0, Float(width), Float(height)], device: gpu)
        let sizes = try buffer([UInt32(pixels.count * 4)], device: gpu)
        let result = try ShaderTranslator().translate(wgsl: program("compute", id: "node_1_grain"), entryPoint: "main", stage: .compute,
            bindings: [TintBinding(group: 0, binding: 0, kind: .texture, slot: 4), TintBinding(group: 0, binding: 1, kind: .storage, slot: 6),
                TintBinding(group: 0, binding: 2, kind: .uniform, slot: 9)],
            bufferSizes: [TintBufferSize(group: 0, binding: 1, index: 0)], bufferSizesOffset: 0, immediateSlot: 30)
        expectEqual(result.workgroupSize.0, 8)
        expectEqual(result.workgroupSize.1, 8)
        expectEqual(result.workgroupSize.2, 1)
        let pipeline = try gpu.makeComputePipelineState(function: function(result, device: gpu))
        let queue = try requireValue(gpu.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let encoder = try requireValue(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 4)
        encoder.setBuffer(output, offset: 0, index: 6)
        encoder.setBuffer(uniforms, offset: 0, index: 9)
        encoder.setBuffer(sizes, offset: 0, index: 30)
        encoder.dispatchThreadgroups(MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        try finish(command)
        let actual = Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: Float.self), count: pixels.count))
        expectEqual(actual, pixels, "Compute dimensions, storage length, parameter offsets, texture addressing and alpha must all match")
        print("METAL-PROBE grain-alpha-zero exact-floats=\(pixels.count)")
    }
}
