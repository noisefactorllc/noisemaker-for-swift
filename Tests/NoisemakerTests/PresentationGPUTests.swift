import Foundation
import MetalKit
import Testing
@testable import Noisemaker
@testable import NoisemakerMetalKit

@Suite(.serialized)
struct PresentationGPUTests {
    @Test func presentedPixelsFlipRawOutputWithoutCPUConversion() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: 257, height: 129, mipmapped: false)
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = [.shaderRead]
        let source = try #require(device.makeTexture(descriptor: sourceDescriptor))
        var words = [UInt16](repeating: 0, count: 257 * 129 * 4)
        for y in 0..<129 { for x in 0..<257 {
            let index = (y * 257 + x) * 4
            words[index] = Float16(y < 64 ? 1 : 0).bitPattern
            words[index + 2] = Float16(y < 64 ? 0 : 1).bitPattern
            words[index + 3] = Float16(1).bitPattern
        } }
        words.withUnsafeBytes { bytes in
            source.replace(region: MTLRegionMake2D(0, 0, 257, 129), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: 257 * 8)
        }
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 257, height: 129, mipmapped: false)
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = [.renderTarget]
        let target = try #require(device.makeTexture(descriptor: targetDescriptor))
        let presenter = try TexturePresenter(device: device)
        let command = try #require(queue.makeCommandBufferWithUnretainedReferences())
        try presenter.encode(source: source, target: target, into: command)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        var bytes = [UInt8](repeating: 0, count: 257 * 129 * 4)
        target.getBytes(&bytes, bytesPerRow: 257 * 4, from: MTLRegionMake2D(0, 0, 257, 129), mipmapLevel: 0)
        #expect(Array(bytes[0..<4]) == [255, 0, 0, 255]) // presented top is raw bottom blue
        let bottom = 128 * 257 * 4
        #expect(Array(bytes[bottom..<(bottom + 4)]) == [0, 0, 255, 255])
        #expect(throws: (any Error).self) { try presenter.encode(source: source, target: source, into: command) }
    }

    @MainActor @Test func unavailableDrawableAndFailedReplacementKeepActiveGraph() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let (graph, _) = try fixture()
        let view = UnavailableView(frame: CGRect(x: 0, y: 0, width: 257, height: 129), device: device)
        view.drawableSize = CGSize(width: 257, height: 129)
        let host = try NoisemakerViewRenderer(view: view, graph: graph)
        let active = host.renderer
        host.draw(in: view)
        #expect(host.frameIndex == 0)
        #expect(host.renderer === active)
        let broken = try fixture(invalidShader: true).0
        #expect(throws: (any Error).self) { try host.replaceGraph(broken) }
        #expect(host.renderer === active)
        _ = host.clock.next(at: 100, index: 0)
        _ = host.clock.next(at: 101, index: 1)
        try host.resize(to: RenderSize(width: 129, height: 65))
        #expect(host.renderer !== active)
        #expect(host.renderer.size.width == 129)
        #expect(host.frameIndex == 0)
        let continued = host.clock.next(at: 102, index: 2)
        #expect(abs(continued.time - 0.2) < 0.00001)
        #expect(abs(continued.delta - 0.1) < 0.00001)
        try host.reset()
    }

    private func fixture(invalidShader: Bool = false) throws -> (RenderGraph, String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reference = root.appendingPathComponent(".build/reference")
        var text = try String(contentsOf: reference.appendingPathComponent("cases/marker.json"), encoding: .utf8)
        if invalidShader {
            // Keep graph identity and metadata valid; preparation must catch bad shader source.
            text = text.replacingOccurrences(of: "@fragment", with: "@invalid_shader_stage")
        }
        let graph = try RenderGraph(exportedCaseData: Data(text.utf8))
        let data = try Data(contentsOf: reference.appendingPathComponent("default-vertex.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (graph, try #require(object["wgsl"] as? String))
    }
}
@MainActor
private final class UnavailableView: MTKView {
    override var currentDrawable: (any CAMetalDrawable)? { nil }
}
