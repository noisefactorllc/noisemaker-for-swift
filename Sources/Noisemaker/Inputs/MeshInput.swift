import Foundation
import Metal

public enum BuiltinMesh: String, CaseIterable, Sendable {
    case sphere, cube, torus, cylinder, cone, capsule, icosphere
    public func load() throws -> OBJMesh {
        guard let url = Bundle.module.url(forResource:rawValue,withExtension:"obj",subdirectory:"meshes") else {
            throw GraphDiagnostic.missing("bundled mesh \(rawValue)")
        }
        return try OBJMesh.parse(String(contentsOf:url,encoding:.utf8))
    }
}

/// Prepares immutable host mesh textures. A mesh surface may be referenced by
/// several graph scopes; each scope shares the same completed upload.
public enum MeshInput {
    public static func prepare(device: MTLDevice, graph: RenderGraph,
                               meshes: [String:OBJMesh], textureSize: RenderSize? = nil) throws -> [String:MTLTexture] {
        let size = try textureSize ?? RenderSize(width:256,height:256)
        var result: [String:MTLTexture] = [:]
        var uploaded: [String:[String:MTLTexture]] = [:]
        for id in graph.externalTextureNames {
            guard id.range(of:#"^global_mesh[0-7]_(positions|normals|uvs)(?:_chain_[0-9]+)?$"#,
                           options:.regularExpression) != nil else { continue }
            let parts = id.split(separator:"_")
            let surface = String(parts[1]), component = String(parts[2])
            if uploaded[surface] == nil {
                guard let mesh = meshes[surface] else { throw GraphDiagnostic.missing("host mesh \(surface)") }
                let packed = try mesh.pack(size:size)
                var textures: [String:MTLTexture] = [:]
                for (name,values) in [("positions",packed.positions),("normals",packed.normals),("uvs",packed.uvs)] {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,
                        width:size.width,height:size.height,mipmapped:false)
                    descriptor.usage = [.shaderRead]
                    descriptor.storageMode = .shared
                    guard let texture = device.makeTexture(descriptor:descriptor) else {
                        throw GraphDiagnostic.missing("mesh texture \(surface).\(name)")
                    }
                    texture.label = "Noisemaker host \(surface).\(name)"
                    values.withUnsafeBytes { raw in
                        texture.replace(region:MTLRegionMake2D(0,0,size.width,size.height),mipmapLevel:0,
                                        withBytes:raw.baseAddress!,bytesPerRow:size.width*16)
                    }
                    textures[name] = texture
                }
                uploaded[surface] = textures
            }
            result[id] = uploaded[surface]![component]!
        }
        return result
    }
}
