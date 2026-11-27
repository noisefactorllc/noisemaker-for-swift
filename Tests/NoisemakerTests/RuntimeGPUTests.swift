import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct RuntimeGPUTests {
    private var reference: URL {
        if let path = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/reference")
    }

    private func renderer(_ name: String, device: MTLDevice) throws -> NoisemakerRenderer {
        let graph = try RenderGraph(exportedCaseData:
            Data(contentsOf: reference.appendingPathComponent("cases/\(name).json")))
        let vertex = try requireValue(JSONSerialization.jsonObject(with:
            Data(contentsOf: reference.appendingPathComponent("default-vertex.json"))) as? [String: Any])
        return try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 257, height: 129),
            defaultVertexWGSL: try requireValue(vertex["wgsl"] as? String),
            vertexEntryPoint: try requireValue(vertex["entryPoint"] as? String))
    }

    private func readback(_ texture: MTLTexture, into command: MTLCommandBuffer,
                          device: MTLDevice) throws -> (MTLBuffer, Int) {
        let bytesPerPixel = texture.pixelFormat == .rgba8Unorm ? 4 : 8
        let rowBytes = ((texture.width * bytesPerPixel + 255) / 256) * 256
        let buffer = try requireValue(device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
        let blit = try requireValue(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        return (buffer, rowBytes)
    }

    private func readback(_ lease: OutputLease, into command: MTLCommandBuffer,
                          device: MTLDevice) throws -> (MTLBuffer, Int) {
        try readback(lease.texture, into: command, device: device)
    }

    private func pixel(_ buffer: MTLBuffer, rowBytes: Int, x: Int, y: Int,
                       format: MTLPixelFormat = .rgba16Float) -> [Float] {
        if format == .rgba8Unorm {
            let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
            return (0..<4).map { c in Float(bytes[y * rowBytes + x * 4 + c]) / 255 }
        }
        let words = buffer.contents().assumingMemoryBound(to: UInt16.self)
        return (0..<4).map { c in Float(Float16(bitPattern: words[y * rowBytes / 2 + x * 4 + c])) }
    }

    @Test func triangleScreenCountUsesMeshDimensionsAndRetainsExplicitOverride() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let shader = """
            struct VertexOutput {
                @builtin(position) position: vec4<f32>,
                @location(0) color: vec4<f32>,
            }
            @vertex fn vertexMain(@builtin(vertex_index) index: u32) -> VertexOutput {
                let vertices = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0),
                    vec2<f32>(-1.0, 3.0), vec2<f32>(3.0, -1.0));
                var output: VertexOutput;
                output.position = vec4<f32>(vertices[index % 3u], select(0.5, 0.25, index >= 3u), 1.0);
                output.color = select(vec4<f32>(1.0, 0.0, 0.0, 1.0),
                    vec4<f32>(0.0, 1.0, 0.0, 1.0), index >= 3u);
                return output;
            }
            @fragment fn main(input: VertexOutput) -> @location(0) vec4<f32> { return input.color; }
            """
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 6, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let mesh = try requireValue(device.makeTexture(descriptor: descriptor))
        let bytes = [UInt8](repeating: 0, count: 24)
        bytes.withUnsafeBytes {
            mesh.replace(region: MTLRegionMake2D(0, 0, 6, 1), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: 24)
        }
        for count in ["auto", "input", "screen"] {
            for (hasMesh, override) in [(true, 0), (true, 3), (false, 0)] {
                var registry = try EffectRegistry.bundled()
                let pass: [String: Any] = ["program": "probe", "drawMode": "triangles",
                    "count": count, "countUniform": "vertexCount", "uniforms": ["vertexCount": override],
                    "inputs": hasMesh ? ["meshPositions": "meshPositions"] : [:],
                    "outputs": ["color": "outputTex"]]
                let definition: [String: Any] = ["namespace": "user", "func": "triangleCountProbe",
                    "starter": true, "externalTexture": "meshPositions", "passes": [pass]]
                try registry.registerPortable(definitionJSON: JSONSerialization.data(withJSONObject: definition),
                    shaderSources: ["probe": shader])
                let graph = try NoisemakerCompiler(registry: registry).compile(source:
                    "search user\ntriangleCountProbe().write(o0)\nrender(o0)\n")
                let renderer = try NoisemakerRenderer(device: device, graph: graph,
                    size: RenderSize(width: 8, height: 8),
                    defaultVertexWGSL: try requireValue(registry.defaultVertex.field("wgsl")?.stringValue),
                    registry: registry)
                let inputs = hasMesh ? Dictionary(uniqueKeysWithValues:
                    graph.externalTextureNames.map { ($0, mesh) }) : [:]
                let command = try requireValue(queue.makeCommandBuffer())
                let output = try renderer.encode(into: command, externalTextures: inputs)
                let (buffer, stride) = try readback(output, into: command, device: device)
                command.commit(); command.waitUntilCompleted()
                expectEqual(command.status, .completed, "\(String(describing: command.error))")
                if let error = command.error { throw error }
                let expected: [Float] = hasMesh && override == 0 ? [0, 1, 0, 1] : [1, 0, 0, 1]
                expectEqual(pixel(buffer, rowBytes: stride, x: 4, y: 4), expected)
            }
        }
    }

    @Test func colorBlendFactorsMatchSourceAndDestinationContributions() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let cases: [([String], [Float])] = [
            (["ONE", "ZERO"], [0.5, 0.5, 0.5, 0.5]),
            (["ZERO", "ONE"], [0.25, 0.5, 1, 1]),
            (["SRC_COLOR", "ZERO"], [0.25, 0.25, 0.25, 0.25]),
            (["DST_COLOR", "ZERO"], [0.125, 0.25, 0.5, 0.5]),
            (["ONE_MINUS_SRC_COLOR", "ZERO"], [0.25, 0.25, 0.25, 0.25]),
            (["ONE_MINUS_DST_COLOR", "ZERO"], [0.375, 0.25, 0, 0]),
            (["SRC_ALPHA", "ONE_MINUS_SRC_ALPHA"], [0.375, 0.5, 0.75, 0.75])
        ]
        let backdrop = "@fragment fn main() -> @location(0) vec4<f32> { return vec4<f32>(0.25, 0.5, 1.0, 1.0); }"
        let source = "@fragment fn main() -> @location(0) vec4<f32> { return vec4<f32>(0.5); }"
        let copy = """
            @group(0) @binding(0) var workTex: texture_2d<f32>;
            @fragment fn main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
                return textureLoad(workTex, vec2<i32>(pos.xy), 0);
            }
            """
        for (factors, expected) in cases {
            var spellings = [factors, factors.map { $0.lowercased() }]
            if factors.contains(where: { $0.contains("_COLOR") }) {
                spellings.append(factors.map { $0.lowercased().replacingOccurrences(of: "_", with: "-") })
            }
            for blend in spellings {
                var registry = try EffectRegistry.bundled()
                let definition: [String: Any] = ["namespace": "user", "func": "factorProbe", "starter": true,
                    "textures": ["work": ["width": 8, "height": 8, "format": "rgba16f"]],
                    "passes": [
                        ["program": "backdrop", "outputs": ["color": "work"]],
                        ["program": "source", "blend": blend, "outputs": ["color": "work"]],
                        ["program": "copy", "inputs": ["workTex": "work"], "outputs": ["color": "outputTex"]]
                    ]]
                try registry.registerPortable(definitionJSON: JSONSerialization.data(withJSONObject: definition),
                    shaderSources: ["backdrop": backdrop, "source": source, "copy": copy])
                let graph = try NoisemakerCompiler(registry: registry).compile(source:
                    "search user\nfactorProbe().write(o0)\nrender(o0)\n")
                let renderer = try NoisemakerRenderer(device: device, graph: graph,
                    size: RenderSize(width: 8, height: 8),
                    defaultVertexWGSL: try requireValue(registry.defaultVertex.field("wgsl")?.stringValue),
                    registry: registry)
                let command = try requireValue(queue.makeCommandBuffer())
                let output = try renderer.encode(into: command)
                let (buffer, stride) = try readback(output, into: command, device: device)
                command.commit(); command.waitUntilCompleted()
                expectEqual(command.status, .completed, "\(String(describing: command.error))")
                if let error = command.error { throw error }
                for y in 0..<8 {
                    for x in 0..<8 {
                        expectEqual(pixel(buffer, rowBytes: stride, x: x, y: y), expected,
                                    "blend \(blend), pixel \(x),\(y)")
                    }
                }
            }
        }
    }

    @Test func testSolidGraphEncodesUpstreamPassesAndKeepsDistinctOutputs() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("solid", device: device)
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let first = try renderer.encode(into: command)
        let (buffer1, stride1) = try readback(first, into: command, device: device)
        command.commit()
        let secondCommand = try requireValue(queue.makeCommandBuffer())
        let second = try renderer.encode(into: secondCommand)
        expectFalse(first.texture === second.texture)
        expectEqual(first.texture.pixelFormat, .rgba16Float)
        let (buffer2, stride2) = try readback(second, into: secondCommand, device: device)
        secondCommand.commit()
        secondCommand.waitUntilCompleted()
        command.waitUntilCompleted()
        expectEqual(secondCommand.status, .completed)
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        for (buffer, stride) in [(buffer1, stride1), (buffer2, stride2)] {
            for (x, y) in [(0, 0), (128, 64), (256, 128)] {
                let rgba = pixel(buffer, rowBytes: stride, x: x, y: y)
                for (actual, expected) in zip(rgba, [Float(0.2), 0.6, 0.9, 1]) {
                    expectTrue(actual.isFinite)
                    expectLess(abs(actual - expected), 0.004)
                }
            }
        }
    }

    @Test func testAsymmetricMarkerRunsThroughGraphBlit() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("marker", device: device)
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: command)
        let (buffer, stride) = try readback(lease, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let corners = [(8, 8), (248, 8), (8, 120), (248, 120)].map {
            pixel(buffer, rowBytes: stride, x: $0.0, y: $0.1)
        }
        let expected: [[Float]] = [[1, 0, 0, 1], [0, 1, 0, 1],
                                   [0, 0, 1, 1], [1, 1, 0, 1]]
        for (actual, wanted) in zip(corners, expected) {
            for (component, reference) in zip(actual, wanted) {
                expectTrue(component.isFinite)
                expectLess(abs(component - reference), 0.004)
            }
        }
    }
    @Test func testComputeRidgeWritesAndConvertsStorageBuffer() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("computeFilter", device: device)
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(frame: FrameState(time: 0.25, delta: 0, frameIndex: 7), into: command)
        let input = try requireValue(lease.graphTexture("node_0_out"))
        let ridged = try requireValue(lease.graphTexture("node_1_out"))
        let (inputBuffer, inputRow) = try readback(input, into: command, device: device)
        let (outputBuffer, outputRow) = try readback(ridged, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        for (x, y) in [(8, 8), (64, 32), (128, 64), (200, 100), (248, 120)] {
            let source = pixel(inputBuffer, rowBytes: inputRow, x: x, y: y)
            let actual = pixel(outputBuffer, rowBytes: outputRow, x: x, y: y)
            for c in 0..<3 {
                let expected = max(0, min(1, 1 - abs(source[c] - 0.4) / 0.6))
                expectTrue(actual[c].isFinite)
                expectLess(abs(actual[c] - expected), 0.006)
            }
            expectLess(abs(actual[3] - 1), 0.004)
        }
    }

    @Test func testMRTWritesDistinctOrderedAttachmentsThenCombinesThem() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("mrtProbe", device: device)
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: command)
        let first = try requireValue(lease.graphTexture("node_0_firstTarget"))
        let second = try requireValue(lease.graphTexture("node_0_secondTarget"))
        let combined = try requireValue(lease.graphTexture("node_0_out"))
        expectEqual(first.pixelFormat, .rgba8Unorm)
        expectEqual(second.pixelFormat, .rgba8Unorm)
        expectFalse(first === second)
        let (firstBuffer, firstRow) = try readback(first, into: command, device: device)
        let (secondBuffer, secondRow) = try readback(second, into: command, device: device)
        let (combinedBuffer, combinedRow) = try readback(combined, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        for (x, y) in [(40, 20), (128, 64), (200, 100)] {
            let a = pixel(firstBuffer, rowBytes: firstRow, x: x, y: y, format: .rgba8Unorm)
            let b = pixel(secondBuffer, rowBytes: secondRow, x: x, y: y, format: .rgba8Unorm)
            let c = pixel(combinedBuffer, rowBytes: combinedRow, x: x, y: y)
            expectLess(abs(a[1]), 0.004)
            expectLess(abs(b[0]), 0.004)
            expectLess(abs(c[0] - a[0]), 0.005)
            expectLess(abs(c[1] - b[1]), 0.005)
            expectLess(abs(c[2] - (1 - (Float(x) + 0.5) / 257)), 0.005)
            expectLess(abs(c[3] - 1), 0.004)
        }
    }

    @Test func testMultipassBlurUsesRgba8IntermediateAndChangesImage() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("multipassBlur", device: device)
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(frame: FrameState(time: 0.25, delta: 0, frameIndex: 7), into: command)
        let input = try requireValue(lease.graphTexture("node_0_out"))
        let intermediate = try requireValue(lease.graphTexture("node_1__blurTemp"))
        let output = try requireValue(lease.graphTexture("node_1_out"))
        expectEqual(intermediate.pixelFormat, .rgba8Unorm)
        let (inputBuffer, inputRow) = try readback(input, into: command, device: device)
        let (outputBuffer, outputRow) = try readback(output, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let samples = [(8, 8), (32, 20), (64, 32), (128, 64), (200, 100), (248, 120)]
        let differences = samples.map { point -> Float in
            let source = pixel(inputBuffer, rowBytes: inputRow, x: point.0, y: point.1)
            let result = pixel(outputBuffer, rowBytes: outputRow, x: point.0, y: point.1)
            return zip(source, result).map { pair in abs(pair.0 - pair.1) }.max() ?? 0
        }
        expectTrue(differences.contains { $0 > 0.01 }, "Blur must change actual source pixels")
        expectTrue(differences.allSatisfy(\.isFinite))
    }

    @Test func testOrdinarySurfaceFractionalSamplesUseNearestFiltering() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("samplerProbe", device: device)
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: command)
        let sampled = try requireValue(lease.graphTexture("node_0_out"))
        let (buffer, stride) = try readback(sampled, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        // The source graph samples at a quarter-pixel offset from a 1-pixel
        // checkerboard. Linear filtering would produce gray at these points.
        for (x, y) in [(100, 64), (101, 64), (100, 65), (101, 65)] {
            let expected: Float = ((x + y) & 1) == 0 ? 0 : 1
            let rgba = pixel(buffer, rowBytes: stride, x: x, y: y)
            for component in rgba.prefix(3) {
                expectLess(abs(component - expected), 0.004)
            }
            expectLess(abs(rgba[3] - 1), 0.004)
        }
    }

    @Test func testVolumeAtlasAndGeometryMRTFlowIntoScreenRender() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let renderer = try renderer("mrtNoise3d", device: device)
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(frame: FrameState(time: 0.25, delta: 0, frameIndex: 7),
            into: command)
        let volume = try requireValue(lease.graphTexture("node_0_volumeCache"))
        let geometry = try requireValue(lease.graphTexture("node_0_geoBuffer"))
        let screenGeometry = try requireValue(lease.graphTexture("node_1_screenGeoBuffer"))
        let image = try requireValue(lease.graphTexture("node_1_out"))
        expectEqual(volume.width, 16)
        expectEqual(volume.height, 256)
        expectEqual(geometry.width, 16)
        expectEqual(geometry.height, 256)
        expectFalse(volume === geometry)
        expectEqual(screenGeometry.width, 257)
        expectEqual(screenGeometry.height, 129)
        expectFalse(screenGeometry === image)
        let (screenBuffer, stride) = try readback(image, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed)
        if let error = command.error { throw error }
        let border = pixel(screenBuffer, rowBytes: stride, x: 0, y: 0)
        let center = pixel(screenBuffer, rowBytes: stride, x: 128, y: 64)
        expectTrue(border.allSatisfy(\.isFinite) && center.allSatisfy(\.isFinite))
        expectTrue(abs(center[0] - border[0]) > 0.1,
            "volume render must use computed atlas, not a constant screen fill")
    }

    @Test func testCatalogColorRGBAUsesVec3AndCommentedBindingIsIgnored() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let compiler = try NoisemakerCompiler()
        let source = """
            search filter, synth
            solid(color: #d1d1d1).texture(alpha: 0.75).write(o0)
            render(o0)
            """
        let graph = try compiler.compile(source: source)
        let color = try requireValue(graph.passes.first?.uniforms.first(where: { $0.name == "color" })?.value.arrayValue)
        expectEqual(color.count, 4, "The source graph preserves the parsed RGBA value")
        let vertex = compiler.registry.defaultVertex
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 64, height: 48),
            defaultVertexWGSL: try requireValue(vertex.field("wgsl")?.stringValue),
            vertexEntryPoint: try requireValue(vertex.field("entryPoint")?.stringValue),
            registry: compiler.registry)
        let queue = try requireValue(device.makeCommandQueue())
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: command)
        let solid = try requireValue(lease.graphTexture("node_0_out"))
        let (solidBuffer, stride) = try readback(solid, into: command, device: device)
        let (finalBuffer, finalStride) = try readback(lease, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let rgba = pixel(solidBuffer, rowBytes: stride, x: 30, y: 20)
        for component in rgba.prefix(3) {
            expectLess(abs(component - Float(209.0 / 255.0)), 0.004)
        }
        expectLess(abs(rgba[3] - 1), 0.004)
        let textured = pixel(finalBuffer, rowBytes: finalStride, x: 30, y: 20)
        expectTrue(textured.allSatisfy(\.isFinite))
    }

    @Test func testSourceCPUOverlayRequiresAndSamplesSuppliedMetalTexture() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let compiler = try NoisemakerCompiler()
        let source = """
            search filter, synth
            solid(color: #000000).fibers(alpha: 1).write(o0)
            render(o0)
            """
        let graph = try compiler.compile(source: source)
        let vertex = compiler.registry.defaultVertex
        let size = try RenderSize(width: 64, height: 48)
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: size, defaultVertexWGSL: try requireValue(vertex.field("wgsl")?.stringValue),
            vertexEntryPoint: try requireValue(vertex.field("entryPoint")?.stringValue),
            registry: compiler.registry)
        let queue = try requireValue(device.makeCommandQueue())
        let missing = try requireValue(queue.makeCommandBuffer())
        expectThrows(try renderer.encode(into: missing))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: size.width, height: size.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let overlay = try requireValue(device.makeTexture(descriptor: descriptor))
        let bytes = [UInt8](repeating: 255, count: size.width * size.height * 4)
        bytes.withUnsafeBytes { pointer in
            overlay.replace(region: MTLRegionMake2D(0, 0, size.width, size.height),
                mipmapLevel: 0, withBytes: pointer.baseAddress!, bytesPerRow: size.width * 4)
        }
        let command = try requireValue(queue.makeCommandBuffer())
        let lease = try renderer.encode(into: command,
            externalTextures: ["node_1_overlayTex": overlay])
        let (buffer, stride) = try readback(lease, into: command, device: device)
        command.commit()
        command.waitUntilCompleted()
        expectEqual(command.status, .completed, "\(String(describing: command.error))")
        if let error = command.error { throw error }
        let result = pixel(buffer, rowBytes: stride, x: 32, y: 24)
        for component in result { expectLess(abs(component - 1), 0.004) }
    }

}
