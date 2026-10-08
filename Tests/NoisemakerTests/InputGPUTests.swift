import Foundation
import Metal
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct InputGPUTests {
    @Test func binaryTextureUploadPreservesAlphaAndOrientation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = try RenderSize(width:3,height:2)
        let data = Data([255,0,0,0, 0,255,0,127, 0,0,255,255, 10,20,30,40, 50,60,70,80, 90,100,110,120])
        for flip in [false,true] {
            let texture = try TextureInput.rgba8(device:device,pixels:data,size:size,flipY:flip)
            var bytes = [UInt8](repeating:0,count:data.count)
            texture.getBytes(&bytes,bytesPerRow:12,from:MTLRegionMake2D(0,0,3,2),mipmapLevel:0)
            let expected = flip ? Data(data.suffix(12) + data.prefix(12)) : data
            #expect(Data(bytes) == expected)
            #expect(texture.pixelFormat == .rgba8Unorm)
        }
        #expect(throws:GraphDiagnostic.self) {try TextureInput.rgba8(device:device,pixels:Data([1]),size:size)}
    }
    @Test func bundledMeshesArePackagedAndIndependent() throws {
        for name in BuiltinMesh.allCases {
            let mesh = try name.load()
            #expect(mesh.vertexCount > 0)
            #expect(mesh.positions.count == mesh.normals.count)
            #expect(mesh.uvs.count == mesh.vertexCount * 2)
        }
    }
}
