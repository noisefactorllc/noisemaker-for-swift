import Foundation

/// De-indexed triangle data with the source OBJ parser's winding and normals.
public struct OBJMesh: Sendable {
    public let positions: [Float]
    public let normals: [Float]
    public let uvs: [Float]
    public var vertexCount: Int { positions.count / 3 }

    public static func parse(_ text: String) throws -> OBJMesh {
        guard text.utf8.count <= 64 * 1024 * 1024 else { throw GraphDiagnostic.invalid("OBJ input exceeds 64 MiB") }
        var rawPositions: [[Double]] = [], rawNormals: [[Double]] = [], rawUVs: [[Double]] = []
        var positions: [Double] = [], normals: [Double] = [], uvs: [Double] = []
        struct Vertex { let position: Int?, uv: Int?, normal: Int? }
        func index(_ value: Substring?) -> Int? {
            guard let value else { return nil }
            let string = String(value)
            guard let range = string.range(of: #"^[+-]?[0-9]+"#, options: .regularExpression),
                  let result = Int(string[range]), result > 0 else { return nil }
            return result - 1
        }
        func numeric(_ parts: [Substring], _ position: Int) -> Double {
            guard parts.indices.contains(position) else { return 0 }
            // JavaScript parseFloat accepts a numeric prefix (and Infinity).
            let text = String(parts[position])
            if text.hasPrefix("Infinity") || text.hasPrefix("+Infinity") { return .infinity }
            if text.hasPrefix("-Infinity") { return -.infinity }
            let pattern = #"^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?"#
            guard let range = text.range(of:pattern,options:.regularExpression),
                  let number = Double(text[range]), !number.isNaN else { return 0 }
            return number == 0 ? 0 : number
        }
        func append(_ vertex: Vertex) {
            if let i = vertex.position, rawPositions.indices.contains(i) { positions.append(contentsOf:rawPositions[i]) }
            else { positions.append(contentsOf:[0,0,0]) }
            if let i = vertex.normal, rawNormals.indices.contains(i) { normals.append(contentsOf:rawNormals[i]) }
            else { normals.append(contentsOf:[0,0,1]) }
            if let i = vertex.uv, rawUVs.indices.contains(i) { uvs.append(contentsOf:rawUVs[i]) }
            else { uvs.append(contentsOf:[0,0]) }
        }
        for rawLine in text.split(separator:"\n",omittingEmptySubsequences:false) {
            let parts = rawLine.split(whereSeparator:{$0.isWhitespace})
            guard let command = parts.first, !command.hasPrefix("#") else { continue }
            switch command {
            case "v": rawPositions.append([numeric(parts,1),numeric(parts,2),numeric(parts,3)])
            case "vn": rawNormals.append([numeric(parts,1),numeric(parts,2),numeric(parts,3)])
            case "vt": rawUVs.append([numeric(parts,1),numeric(parts,2)])
            case "f":
                let face = parts.dropFirst().map { value -> Vertex in
                    let fields = value.split(separator:"/",omittingEmptySubsequences:false)
                    return Vertex(position:index(fields.first),uv:index(fields.count > 1 ? fields[1] : nil),
                                  normal:index(fields.count > 2 ? fields[2] : nil))
                }
                guard face.count >= 3 else { continue }
                guard positions.count / 3 + (face.count - 2) * 3 <= 4_000_000 else {
                    throw GraphDiagnostic.invalid("OBJ input exceeds four million expanded vertices")
                }
                for i in 1..<(face.count - 1) { append(face[0]); append(face[i+1]); append(face[i]) }
            default: break
            }
        }
        if rawNormals.isEmpty && !positions.isEmpty { smoothNormals(positions:positions,normals:&normals) }
        return OBJMesh(positions:positions.map(Float.init),normals:normals.map(Float.init),uvs:uvs.map(Float.init))
    }

    private static func smoothNormals(positions: [Double], normals: inout [Double]) {
        let count = positions.count / 3
        var faces = [Float](repeating:0,count:count)
        func normalized(_ x:Double,_ y:Double,_ z:Double) -> [Double] {
            let length = sqrt(x*x + y*y + z*z)
            return length > 0.0001 ? [x/length,y/length,z/length] : [0,0,1]
        }
        for triangle in 0..<(count/3) {
            let a = triangle * 9, b = a + 3, c = a + 6
            let e1x = positions[b]-positions[a], e1y = positions[b+1]-positions[a+1], e1z = positions[b+2]-positions[a+2]
            let e2x = positions[c]-positions[a], e2y = positions[c+1]-positions[a+1], e2z = positions[c+2]-positions[a+2]
            let normal = normalized(e1y*e2z-e1z*e2y,e1z*e2x-e1x*e2z,e1x*e2y-e1y*e2x)
            for component in 0..<3 { faces[triangle*3+component] = Float(normal[component]) }
        }
        // Source groups by Math.round(component * 10000) / 10000.
        struct Position: Hashable { let x:Double, y:Double, z:Double }
        func key(_ vertex:Int) -> Position {
            func round(_ value:Double) -> Double { floor(value*10000 + 0.5)/10000 }
            return Position(x:round(positions[vertex*3]),y:round(positions[vertex*3+1]),z:round(positions[vertex*3+2]))
        }
        var sums: [Position:[Double]] = [:]
        for vertex in 0..<count {
            let position = key(vertex), face = (vertex/3)*3
            var sum = sums[position] ?? [0,0,0]
            for component in 0..<3 { sum[component] += Double(faces[face+component]) }
            sums[position] = sum
        }
        for (position,sum) in sums { sums[position] = normalized(sum[0],sum[1],sum[2]) }
        for vertex in 0..<count {
            let normal = sums[key(vertex)] ?? [0,0,1]
            for component in 0..<3 { normals[vertex*3+component] = normal[component] }
        }
    }

    public func pack(size: RenderSize) throws -> PackedMesh {
        let count = size.width * size.height
        guard count <= 4_000_000 else { throw GraphDiagnostic.invalid("mesh texture exceeds four million vertices") }
        let used = min(vertexCount,count)
        var positionData = [Float](repeating:0,count:count*4)
        var normalData = positionData, uvData = positionData
        for vertex in 0..<used {
            for component in 0..<3 {
                positionData[vertex*4+component] = positions[vertex*3+component]
                normalData[vertex*4+component] = normals[vertex*3+component]
            }
            positionData[vertex*4+3] = 1
            uvData[vertex*4] = uvs[vertex*2]
            uvData[vertex*4+1] = uvs[vertex*2+1]
        }
        return PackedMesh(size:size,positions:positionData,normals:normalData,uvs:uvData,vertexCount:used)
    }
}

public struct PackedMesh: Sendable {
    public let size: RenderSize
    public let positions: [Float]
    public let normals: [Float]
    public let uvs: [Float]
    public let vertexCount: Int
}
