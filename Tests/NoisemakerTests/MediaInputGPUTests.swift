import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct MediaInputGPUTests {
    @Test func mediaUsesHostDimensionsAndRetainsInputThroughCompletion() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let compiler = try NoisemakerCompiler()
        let graph = try compiler.compile(source:"search synth\nmedia().write(o0)")
        #expect(graph.mediaSteps.count == 1)
        #expect(graph.mediaSteps[0].textureId == "imageTex_step_0")
        let size = try RenderSize(width:65,height:33)
        let renderer = try NoisemakerRenderer(device:device,graph:graph,size:size)
        let hostSize = try RenderSize(width:17,height:11)
        let pixels = Data((0..<(17*11)).flatMap {_ in [UInt8(51),102,153,255]})
        var texture:MTLTexture? = try TextureInput.rgba8(device:device,pixels:pixels,size:hostSize)
        weak var weakTexture = texture
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBufferWithUnretainedReferences())
        let output = try renderer.encode(frame:.zero,into:command,externalTextures:["imageTex_step_0":texture!])
        texture = nil
        #expect(weakTexture != nil)
        command.commit();command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(command.error == nil)
        #expect(output.texture.width == 65)
        #expect(output.texture.height == 33)
    }
    @Test func repeatedTextStepsHaveDistinctBindings() throws {
        let compiler = try NoisemakerCompiler()
        let graph = try compiler.compile(source:"search synth, filter\nsolid().text(text: \"first\").text(text: \"second\").write(o0)")
        #expect(graph.mediaSteps.map(\.textureId) == ["textTex_step_1","textTex_step_2"])
        #expect(Set(graph.externalTextureNames) == ["textTex_step_1","textTex_step_2"])
    }
}
