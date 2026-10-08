import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized) struct RemapGPUTests {
    @Test func packedStructAndDirectVectorBindingsCoexist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let corpus = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("parity/corpus.json"))) as? [String: Any])
        let cases = try #require(corpus["cases"] as? [[String: Any]])
        let source = try #require(cases.first { $0["id"] as? String == "coverage/synth_remap" }?["source"] as? String)
        let graph = try NoisemakerCompiler().compile(source: source)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: 257, height: 129))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let output = try renderer.encode(into: command)
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(command.error == nil)
        #expect(output.texture.width == 257 && output.texture.height == 129)
    }
}
