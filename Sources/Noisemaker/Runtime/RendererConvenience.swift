import Foundation
import Metal

package enum BundledShaderSources {
    private static let vertexResult: Result<(wgsl: String, entryPoint: String), any Error> = Result {
        let vertex = try EffectRegistry.bundled().defaultVertex
        guard let source = vertex.field("wgsl")?.stringValue,
              let entry = vertex.field("entryPoint")?.stringValue else {
            throw CatalogError.malformed("bundled default vertex shader")
        }
        return (source, entry)
    }
    package static func vertex() throws -> (wgsl: String, entryPoint: String) { try vertexResult.get() }
}

extension NoisemakerRenderer {
    /// Uses the source-bound vertex shader shipped in this Swift package.
    public convenience init(device: MTLDevice, graph: RenderGraph, size: RenderSize,
                            maximumTextureDimension2D: Int? = nil) throws {
        let vertex = try BundledShaderSources.vertex()
        try self.init(device: device, graph: graph, size: size,
            defaultVertexWGSL: vertex.wgsl, vertexEntryPoint: vertex.entryPoint,
            maximumTextureDimension2D: maximumTextureDimension2D)
    }
}
