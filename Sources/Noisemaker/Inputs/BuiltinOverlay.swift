import CNoisemakerRaster
import Foundation

public enum BuiltinOverlayKind: String, Sendable {
    case fibers, scratches, strayHair
}

/// Straight-alpha, top-down RGBA8 pixels for a host's texture upload.
public struct OverlayPixels: Sendable {
    public let size: RenderSize
    public let rgba: Data
}

/// CPU preparation of the catalog's one-shot overlay inputs. Call away from
/// the live draw loop and publish the completed texture at a frame boundary.
public enum BuiltinOverlay {
    public static func render(_ kind: BuiltinOverlayKind, size: RenderSize,
                              seed: Double = 1, density: Double? = nil) throws -> OverlayPixels {
        let density = density ?? (kind == .scratches ? 0.3 : 0.5)
        guard seed.isFinite, density.isFinite, (0...1).contains(density) else {
            throw GraphDiagnostic.invalid("overlay seed or density is invalid")
        }
        guard let canvas = nm_raster_create(Int32(size.width), Int32(size.height)) else {
            throw GraphDiagnostic.missing("CPU overlay raster canvas")
        }
        defer { nm_raster_destroy(canvas) }
        var record = [Double](repeating: 0, count: 9)
            let seed = seed == 0 ? 1 : seed
            let layerCount = kind == .strayHair ? 1 : 4
            for layer in 0..<layerCount {
                let layerSeed = seed * 1000 + (kind == .fibers ? Double(layer * 137) :
                    kind == .scratches ? Double(layer * 251) : 42)
                let options: WormOptions
                switch kind {
                case .fibers:
                    options = WormOptions(width:size.width,height:size.height,seed:layerSeed,density:0.5 + density * 2,
                        kink:5 + layerSeed.truncatingRemainder(dividingBy:5),stride:0.75,strideDeviation:0.125,
                        duration:1,flowFrequency:4,lineWidth:max(1.5,Double(size.width) / 384),behavior:"chaotic")
                case .scratches:
                    options = WormOptions(width:size.width,height:size.height,seed:layerSeed,density:0.1 + density * 0.4,
                        kink:0.125 + layerSeed.truncatingRemainder(dividingBy:50) / 400,stride:0.75,strideDeviation:0.5,
                        duration:2 + layerSeed.truncatingRemainder(dividingBy:3),
                        flowFrequency:2 + layerSeed.truncatingRemainder(dividingBy:3),
                        lineWidth:max(0.5,Double(size.width) / 1024),
                        behavior:layerSeed.truncatingRemainder(dividingBy:2) == 0 ? "obedient" : "unruly")
                case .strayHair:
                    options = WormOptions(width:size.width,height:size.height,seed:layerSeed,density:0.001 + density * 0.004,
                        kink:5 + layerSeed.truncatingRemainder(dividingBy:45),stride:0.5,strideDeviation:0.25,
                        duration:8 + layerSeed.truncatingRemainder(dividingBy:8),flowFrequency:4,
                        lineWidth:max(1,Double(size.width) / 400),behavior:"unruly")
                }
                try WormTracer.trace(options,color:{ rng,_ in
                    switch kind {
                    case .fibers: return WormColor(red:floor(rng.float() * 200 + 55),green:floor(rng.float() * 200 + 55),
                                                   blue:floor(rng.float() * 200 + 55),alpha:0.5)
                    case .scratches: return WormColor(red:255,green:255,blue:255,alpha:1)
                    case .strayHair: return WormColor(red:floor(rng.float() * 30),green:floor(rng.float() * 30),
                                                     blue:floor(rng.float() * 30),alpha:0.666)
                    }
                },emit:{ segment in
                    record[0] = segment.x; record[1] = segment.y
                    record[2] = segment.endX; record[3] = segment.endY
                    record[4] = segment.lineWidth
                    record[5] = segment.color.red; record[6] = segment.color.green
                    record[7] = segment.color.blue; record[8] = segment.color.alpha
                    let status = record.withUnsafeBufferPointer {
                        nm_raster_stroke(canvas, $0.baseAddress)
                    }
                    guard status == 0 else {
                        throw status == 1 ? GraphDiagnostic.invalid("overlay stroke is invalid") :
                            GraphDiagnostic.missing("CPU overlay raster stroke")
                    }
                })
            }
        var bytes = Data(count:size.width * size.height * 4)
        let status = bytes.withUnsafeMutableBytes { raw in
            nm_raster_read_rgba8(canvas, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
        }
        guard status == 0 else {
            throw GraphDiagnostic.missing("CPU overlay raster readback")
        }
        return OverlayPixels(size:size,rgba:bytes)
    }
}
