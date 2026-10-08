import CoreGraphics
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
        var bytes = Data(count:size.width * size.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name:CGColorSpace.sRGB),
                  let context = CGContext(data:raw.baseAddress,width:size.width,height:size.height,
                    bitsPerComponent:8,bytesPerRow:size.width * 4,space:space,
                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw GraphDiagnostic.missing("CPU overlay bitmap context")
            }
            context.translateBy(x:0,y:CGFloat(size.height))
            context.scaleBy(x:1,y:-1)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setShouldAntialias(true)
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
                    context.setLineWidth(segment.lineWidth)
                    context.setStrokeColor(red:segment.color.red / 255,green:segment.color.green / 255,
                                           blue:segment.color.blue / 255,alpha:segment.color.alpha)
                    context.beginPath()
                    context.move(to:CGPoint(x:segment.x,y:segment.y))
                    context.addLine(to:CGPoint(x:segment.endX,y:segment.endY))
                    context.strokePath()
                })
            }
            // Canvas external-image uploads expose straight alpha. Quartz draws
            // into premultiplied storage, so convert only after every stroke.
            let pixels = raw.bindMemory(to:UInt8.self)
            for pixel in stride(from:0,to:pixels.count,by:4) {
                let alpha = Int(pixels[pixel + 3])
                if alpha > 0 {
                    for component in 0..<3 {
                        pixels[pixel + component] = UInt8(min(255,(Int(pixels[pixel + component]) * 255 + alpha / 2) / alpha))
                    }
                }
            }
        }
        return OverlayPixels(size:size,rgba:bytes)
    }
}
