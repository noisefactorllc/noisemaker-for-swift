import Foundation
import CryptoKit
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct OBJMeshTests {
    @Test func indexedGeometryPackingAndEmptyUpload() throws {
        let mesh = OBJMesh(positions: [1, 2, 3, 4, 5, 6], normals: [0, 0, 1, 0, 1, 0],
                           indices: [1, 0, 1])
        #expect(mesh.vertexCount == 2 && mesh.triangleCount == 1)
        #expect(try mesh.deindexed().positions == [4, 5, 6, 1, 2, 3, 4, 5, 6])
        let packed = try mesh.pack()
        #expect(packed.size.width == 2 && packed.size.height == 2)
        #expect(packed.positions == [4,5,6,1, 1,2,3,1, 4,5,6,1, 0,0,0,0])
        #expect(packed.uvs == Array(repeating: 0, count: 16))
        let empty = try OBJMesh(positions: [], normals: [], indices: []).pack()
        #expect(empty.size.width == 1 && empty.size.height == 1 && empty.vertexCount == 0)
        #expect(empty.positions == [0,0,0,0])
        let missing = try OBJMesh(positions: [1,2,3], normals: [], indices: [4]).pack()
        #expect(missing.positions[0].isNaN && missing.normals[0].isNaN && missing.uvs[0].isNaN)
        #expect(missing.positions[3] == 1)
    }

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
    @Test func indexedGeometryMatchesPinnedSharedModule() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let oracle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("parity/obj-oracle.json"))) as? [String: Any])
        let cases = try #require(oracle["geometryCases"] as? [[String: Any]])
        #expect(cases.count == 4)
        for item in cases {
            let id = try #require(item["id"] as? String)
            let attributes = try #require(item["attributes"] as? [String: [Double]])
            let mesh = OBJMesh(positions: try #require(attributes["positions"]).map(Float.init),
                               normals: try #require(attributes["normals"]).map(Float.init),
                               uvs: (attributes["uvs"] ?? []).map(Float.init),
                               indices: try #require(attributes["indices"]).map(UInt32.init))
            let expanded = try mesh.deindexed()
            let packed = try mesh.pack()
            let dimensions = try #require(item["dimensions"] as? [String: Int])
            #expect(packed.size.width == dimensions["texWidth"] && packed.size.height == dimensions["texHeight"])
            #expect(mesh.vertexCount == item["vertexCount"] as? Int && mesh.triangleCount == item["triangleCount"] as? Double)
            for (stage, arrays) in [("expanded", ["positions": expanded.positions, "normals": expanded.normals, "uvs": expanded.uvs]),
                                    ("packed", ["positions": packed.positions, "normals": packed.normals, "uvs": packed.uvs])] {
                let records = try #require(item[stage] as? [String: Any])
                for (name, values) in arrays {
                    let record = try #require(records[name] as? [String: Any])
                    var bytes = Data()
                    for value in values {
                        var bits = value.bitPattern.littleEndian
                        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
                    }
                    #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == record["sha256"] as? String, "\(id) \(stage).\(name)")
                }
            }
        }
    }

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
            #expect(mesh.indices == (0..<mesh.vertexCount).map(UInt32.init))
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
