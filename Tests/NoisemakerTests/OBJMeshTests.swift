import Foundation
import CryptoKit
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct OBJMeshTests {
    @Test func windingNormalsAndTexturePacking() throws {
        let mesh = try OBJMesh.parse("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3")
        #expect(mesh.positions == [0,0,0, 0,1,0, 1,0,0])
        #expect(mesh.normals == [0,0,-1, 0,0,-1, 0,0,-1])
        #expect(mesh.uvs == [0,0,0,0,0,0])
        let packed = try mesh.pack(size:RenderSize(width:2,height:2))
        #expect(packed.vertexCount == 3)
        #expect(packed.positions == [0,0,0,1, 0,1,0,1, 1,0,0,1, 0,0,0,0])
        #expect(packed.normals == [0,0,-1,0, 0,0,-1,0, 0,0,-1,0, 0,0,0,0])
        #expect(try mesh.pack(size:RenderSize(width:1,height:1)).vertexCount == 1)
    }
    @Test func sourceIntegerPrefixesStopAtTheFirstNondigit() throws {
        let mesh = try OBJMesh.parse("v 2 3 4\nv 5 6 7\nv 8 9 10\nf 1-2 2e3 3+4")
        #expect(mesh.positions == [2,3,4,8,9,10,5,6,7])
    }
    @Test func sourceTreatsNegativeAndMissingIndicesAsZero() throws {
        let mesh = try OBJMesh.parse("v 1 2 3\nvn 0 1 0\nf -1 1//1 nope")
        #expect(mesh.positions == [0,0,0, 0,0,0, 1,2,3])
        #expect(mesh.normals == [0,0,1, 0,0,1, 0,1,0])
    }
}

extension OBJMeshTests {
    @Test func parsedAndPackedBytesMatchPinnedSource() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("parity/obj-oracle.json"))) as? [String:Any])
        let cases = try #require(fixture["builtins"] as? [[String:Any]]) + #require(fixture["edgeCases"] as? [[String:Any]])
        for item in cases {
            let id = try #require(item["id"] as? String)
            let source = try #require(item["source"] as? [String:Any])
            let text: String
            if let body = source["text"] as? String { text = body }
            else {
                let path = try #require(source["path"] as? String)
                text = try String(contentsOf:root.appendingPathComponent("Sources/Noisemaker/Resources/meshes/" + URL(fileURLWithPath:path).lastPathComponent),encoding:.utf8)
            }
            let mesh = try OBJMesh.parse(text)
            let texture = try #require(item["texture"] as? [String:Int])
            let packed = try mesh.pack(size:RenderSize(width:#require(texture["width"]),height:#require(texture["height"])))
            #expect(mesh.vertexCount == item["vertexCount"] as? Int, "\(id) vertex count")
            #expect(packed.vertexCount == item["packedVertexCount"] as? Int, "\(id) packed count")
            for (stage,arrays) in [("parsed",["positions":mesh.positions,"normals":mesh.normals,"uvs":mesh.uvs]),
                                   ("packed",["positions":packed.positions,"normals":packed.normals,"uvs":packed.uvs])] {
                let oracle = try #require(item[stage] as? [String:[String:Any]])
                for (name,values) in arrays {
                    let record = try #require(oracle[name])
                    var bytes = Data(capacity:values.count * 4)
                    for value in values {
                        var bits = value.bitPattern.littleEndian
                        withUnsafeBytes(of:&bits) { bytes.append(contentsOf:$0) }
                    }
                    let digest = SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined()
                    #expect(digest == record["sha256"] as? String, "\(id) \(stage).\(name)")
                    #expect(values.count == record["length"] as? Int)
                }
            }
        }
    }
}
