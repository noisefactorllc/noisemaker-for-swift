import Foundation

public enum GraphDimension {
    case screen
    case fixed(Int)
    case percent(Double)
    case scale(factor: Double, minimum: Double?, maximum: Double?)
    case parameter(name: String, fallback: Double, power: Double, multiply: Double)
    case screenDivide(name: String, fallback: Double)

    static func decode(_ value: GraphValue, context: String) throws -> GraphDimension {
        switch value {
        case .number(let number):
            guard number.isFinite else {
                throw GraphDiagnostic.unsupported("\(context) dimension \(number)")
            }
            let pixels = max(1, number.rounded(.down))
            guard pixels <= 16_384 else {
                throw GraphDiagnostic.unsupported("\(context) dimension \(number)")
            }
            return .fixed(Int(pixels))
        case .string(let name):
            if ["screen", "auto", "input", "resolution"].contains(name) { return .screen }
            if name.hasSuffix("%"), let percent = Double(name.dropLast()),
               percent.isFinite, percent > 0, percent <= 100 {
                return .percent(percent)
            }
        case .object(let fields):
            let keys = Set(fields.map(\.name))
            if let override = value.field("inputOverride"),
               override.stringValue?.isEmpty != false {
                throw GraphDiagnostic.unsupported("\(context) invalid inputOverride dimension field")
            }
            if let name = value.field("param")?.stringValue,
               keys.isSubset(of: ["param", "default", "paramDefault", "power", "multiply", "inputOverride"]) {
                for key in ["default", "paramDefault", "power", "multiply"] {
                    if let raw = value.field(key), raw.numberValue == nil {
                        throw GraphDiagnostic.unsupported("\(context) invalid \(key) dimension field")
                    }
                }
                let baseFallback = value.field("paramDefault")?.numberValue ?? 64
                let power = value.field("power")?.numberValue ?? 1
                let multiply = value.field("multiply")?.numberValue ?? 1
                guard baseFallback.isFinite, power.isFinite, multiply.isFinite else {
                    throw GraphDiagnostic.unsupported("\(context) nonfinite parameter dimension")
                }
                let hasTransform = value.field("power") != nil || value.field("multiply") != nil
                let computedFallback = Foundation.pow(baseFallback * multiply, power)
                let finalFallback = hasTransform
                    ? (value.field("default")?.numberValue ?? computedFallback)
                    : baseFallback
                guard finalFallback.isFinite else {
                    throw GraphDiagnostic.unsupported("\(context) nonfinite fallback dimension")
                }
                return .parameter(name: name, fallback: finalFallback,
                    power: power, multiply: multiply)
            }
            if let name = value.field("screenDivide")?.stringValue,
               keys.isSubset(of: ["screenDivide", "default", "inputOverride"]) {
                if let raw = value.field("default"), raw.numberValue == nil {
                    throw GraphDiagnostic.unsupported("\(context) invalid divisor default")
                }
                let fallback = value.field("default")?.numberValue ?? 1
                guard fallback.isFinite, fallback > 0 else {
                    throw GraphDiagnostic.unsupported("\(context) invalid divisor")
                }
                return .screenDivide(name: name, fallback: fallback)
            }
            if let factor = value.field("scale")?.numberValue,
               keys.isSubset(of: ["scale", "clamp", "inputOverride"]) {
                guard factor.isFinite, factor > 0 else {
                    throw GraphDiagnostic.unsupported("\(context) invalid scale")
                }
                let minimum: Double?, maximum: Double?
                if let clamp = value.field("clamp") {
                    guard let fields = clamp.objectFields,
                          Set(fields.map(\.name)).isSubset(of: ["min", "max"]) else {
                        throw GraphDiagnostic.unsupported("\(context) invalid scale clamp")
                    }
                    minimum = clamp.field("min")?.numberValue
                    maximum = clamp.field("max")?.numberValue
                    guard (clamp.field("min") == nil || minimum?.isFinite == true),
                          (clamp.field("max") == nil || maximum?.isFinite == true) else {
                        throw GraphDiagnostic.unsupported("\(context) invalid scale clamp bound")
                    }
                } else {
                    minimum = nil
                    maximum = nil
                }
                return .scale(factor: factor, minimum: minimum, maximum: maximum)
            }
        default: break
        }
        throw GraphDiagnostic.unsupported("\(context) dimension is not supported")
    }

    func resolve(screen: Int, parameters: [String: Double]) throws -> Int {
        let value: Double
        switch self {
        case .screen: value = Double(screen)
        case .fixed(let pixels): value = Double(pixels)
        case .percent(let percent): value = Double(screen) * percent / 100
        case .scale(let factor, let minimum, let maximum):
            var scaled = (Double(screen) * factor).rounded(.down)
            if let minimum { scaled = max(minimum, scaled) }
            if let maximum { scaled = min(maximum, scaled) }
            value = max(1, scaled)
        case .parameter(let name, let fallback, let power, let multiply):
            value = parameters[name].map { Foundation.pow($0 * multiply, power) } ?? fallback
        case .screenDivide(let name, let fallback):
            let divisor = parameters[name] ?? fallback
            guard divisor > 0 else { throw GraphDiagnostic.unsupported("invalid screen divisor \(name)") }
            value = (Double(screen) / divisor).rounded()
        }
        guard value.isFinite else {
            throw GraphDiagnostic.unsupported("resolved texture dimension \(value) is not finite")
        }
        let resolved = max(1, value.rounded(.down))
        guard resolved <= 16_384 else {
            throw GraphDiagnostic.unsupported("resolved texture dimension \(value) exceeds device subset")
        }
        return Int(resolved)
    }
}

extension GraphValue {
    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
