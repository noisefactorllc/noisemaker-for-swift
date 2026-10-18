import Foundation
import Metal

/// Prepares the graph inputs that the package generates itself: the fibers,
/// scratches and strayHair overlays, and the mesh0 surface. render.meshLoader
/// loads the bundled sphere there unless a host supplies a mesh. Text, media
/// and custom meshes remain host content.
public enum NativeInputs {
    public static func prepare(device: MTLDevice, graph: RenderGraph,
                               size: RenderSize) throws -> [String: MTLTexture] {
        var textures: [String: MTLTexture] = [:]
        for (id, overlay) in try BuiltinOverlay.prepare(graph: graph, size: size) {
            textures[id] = try TextureInput.rgba8(device: device, pixels: overlay.rgba, size: overlay.size)
        }
        let meshNames = graph.externalTextureNames.filter {
            $0.range(of: #"^global_mesh[0-7]_(positions|normals|uvs)(?:_chain_[0-9]+)?$"#,
                     options: .regularExpression) != nil
        }
        guard !meshNames.isEmpty, meshNames.allSatisfy({ $0.hasPrefix("global_mesh0_") }) else {
            return textures
        }
        let loadsMesh = graph.passes.contains {
            $0.raw.field("effectKey")?.stringValue == "render.meshLoader"
        }
        let mesh = try loadsMesh ? BuiltinMesh.sphere.load() : OBJMesh.parse("")
        textures.merge(try MeshInput.prepare(device: device, graph: graph, meshes: ["mesh0": mesh])) { $1 }
        return textures
    }
}
