import Foundation

/// JavaScript's PCG-like generator deliberately multiplies as binary64 before
/// ToUint32. Wrapping UInt32 multiplication would produce different trails.
struct WormRNG {
    private var state: UInt32
    init(seed: Double) {
        state = Self.uint32(Double(Self.uint32(seed)) * 747_796_405 + 2_891_336_453)
    }
    mutating func next() -> UInt32 {
        state = Self.uint32(Double(state) * 747_796_405 + 2_891_336_453)
        let shifted = (state >> ((state >> 28) + 4)) ^ state
        let word = Self.uint32(Double(Int32(bitPattern:shifted)) * 277_803_737)
        return (word >> 22) ^ word
    }
    mutating func float() -> Double { Double(next()) / 4_294_967_295 }
    mutating func normal(mean: Double, deviation: Double) -> Double {
        let u1 = max(float(), 1e-10), u2 = float()
        return mean + deviation * sqrt(-2 * log(u1)) * cos(Double.pi * 2 * u2)
    }
    private static func uint32(_ number: Double) -> UInt32 {
        guard number.isFinite else { return 0 }
        let remainder = number.rounded(.towardZero).truncatingRemainder(dividingBy: 4_294_967_296)
        return UInt32(remainder < 0 ? remainder + 4_294_967_296 : remainder)
    }
}

struct WormOptions {
    let width: Int, height: Int
    let seed: Double, density: Double, kink: Double, stride: Double, strideDeviation: Double
    let duration: Double, flowFrequency: Double, lineWidth: Double
    let behavior: String
}
struct WormColor: Sendable {
    let red: Double, green: Double, blue: Double, alpha: Double
}
struct WormSegment: Sendable {
    let x: Double, y: Double, endX: Double, endY: Double
    let color: WormColor
    let lineWidth: Double
}

enum WormTracer {
    private static let tau = Double.pi * 2
    private struct Worm {
        let x: Double, y: Double, stride: Double, rotation: Double
        let color: WormColor
    }
    static func trace(_ options: WormOptions, color: (inout WormRNG, Int) -> WormColor,
                      emit: (WormSegment) throws -> Void) throws {
        guard options.width > 0, options.height > 0, options.width <= 16_384, options.height <= 16_384,
              [options.seed, options.density, options.kink, options.stride, options.strideDeviation,
               options.duration, options.flowFrequency, options.lineWidth].allSatisfy(\.isFinite),
              options.density >= 0, options.duration >= 0, options.flowFrequency >= 0,
              options.flowFrequency <= 1024, options.lineWidth > 0,
              ["obedient","unruly","chaotic"].contains(options.behavior) else {
            throw GraphDiagnostic.invalid("worm overlay parameters are invalid")
        }
        let width = Double(options.width), height = Double(options.height)
        let maximum = max(width,height), minimum = min(width,height)
        let rawCount = max(1,floor(maximum * options.density))
        let rawIterations = max(1,floor(sqrt(minimum) * options.duration))
        guard rawCount <= 1_000_000, rawIterations <= 1_000_000,
              rawCount * rawIterations <= 16_000_000 else {
            throw GraphDiagnostic.invalid("worm overlay exceeds bounded segment capacity")
        }
        let count = Int(rawCount), iterations = Int(rawIterations)
        var rng = WormRNG(seed:options.seed)
        let field = noise(width:options.width,height:options.height,frequency:options.flowFrequency,seed:options.seed * 31_337)
        let sharedRotation = rng.float() * tau
        var worms: [Worm] = []
        worms.reserveCapacity(count)
        for index in 0..<count {
            let x = rng.float() * width, y = rng.float() * height
            let stride = rng.normal(mean:options.stride,deviation:options.strideDeviation) * (maximum / 1024)
            let rotation = options.behavior == "obedient" ? sharedRotation : rng.float() * tau
            worms.append(Worm(x:x,y:y,stride:stride,rotation:rotation,color:color(&rng,index)))
        }
        for worm in worms {
            var x = worm.x, y = worm.y
            for iteration in 0..<iterations {
                let t = iterations > 1 ? Double(iteration) / Double(iterations - 1) : 1
                let exposure = 1 - abs(1 - t * 2)
                let fx = Int(floor((x.truncatingRemainder(dividingBy:width) + width).truncatingRemainder(dividingBy:width)))
                let fy = Int(floor((y.truncatingRemainder(dividingBy:height) + height).truncatingRemainder(dividingBy:height)))
                let baseAngle = Double(field[fy * options.width + fx]) * tau * options.kink
                let angle = baseAngle + (options.behavior == "obedient" ? sharedRotation : worm.rotation)
                let endX = x + sin(angle) * worm.stride, endY = y + cos(angle) * worm.stride
                try emit(WormSegment(x:x,y:y,endX:endX,endY:endY,
                    color:WormColor(red:worm.color.red,green:worm.color.green,blue:worm.color.blue,
                                    alpha:worm.color.alpha * exposure),lineWidth:options.lineWidth))
                x = endX; y = endY
            }
        }
    }
    private static func noise(width:Int,height:Int,frequency:Double,seed:Double) -> [Float] {
        let gridWidth = Int(ceil(frequency)) + 2
        var rng = WormRNG(seed:seed)
        let grid = (0..<(gridWidth * gridWidth)).map { _ in Float(rng.float()) }
        var result = [Float](repeating:0,count:width * height)
        for y in 0..<height { for x in 0..<width {
            let fx = (Double(x) / Double(width)) * frequency
            let fy = (Double(y) / Double(height)) * frequency
            let ix = Int(floor(fx)), iy = Int(floor(fy))
            let dx = fx - floor(fx), dy = fy - floor(fy)
            let sx = dx * dx * (3 - 2 * dx), sy = dy * dy * (3 - 2 * dy)
            let tl = Double(grid[iy * gridWidth + ix]), tr = Double(grid[iy * gridWidth + ix + 1])
            let bl = Double(grid[(iy + 1) * gridWidth + ix]), br = Double(grid[(iy + 1) * gridWidth + ix + 1])
            result[y * width + x] = Float((tl * (1 - sx) + tr * sx) * (1 - sy) + (bl * (1 - sx) + br * sx) * sy)
        } }
        return result
    }
}
