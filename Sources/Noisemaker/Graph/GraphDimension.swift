import Foundation

public enum GraphDimension {
    case screen
    case fixed(Int)
    case percent(Double)
    case parameter(name: String, fallback: Double, power: Double, multiply: Double)
    case screenDivide(name: String, fallback: Double)

    static func decode(_ value: GraphValue, context: String) throws -> GraphDimension {
        switch value {
        case .number(let number):
            guard number.isFinite, number >= 1, number <= 16_384 else {
                throw GraphDiagnostic.unsupported("\(context) dimension \(number)")
            }
            return .fixed(Int(number.rounded(.down)))
        case .string(let name):
            if ["screen", "auto", "input", "resolution"].contains(name) { return .screen }
            if name.hasSuffix("%"), let percent = Double(name.dropLast()),
               percent.isFinite, percent > 0, percent <= 100 {
                return .percent(percent)
            }
        case .object(let fields):
            let keys = Set(fields.map(\.name))
            if let name = value.field("param")?.stringValue,
               keys.isSubset(of: ["param", "default", "paramDefault", "power", "multiply"]) {
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
               keys.isSubset(of: ["screenDivide", "default"]) {
                if let raw = value.field("default"), raw.numberValue == nil {
                    throw GraphDiagnostic.unsupported("\(context) invalid divisor default")
                }
                let fallback = value.field("default")?.numberValue ?? 1
                guard fallback.isFinite, fallback > 0 else {
                    throw GraphDiagnostic.unsupported("\(context) invalid divisor")
                }
                return .screenDivide(name: name, fallback: fallback)
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
        case .parameter(let name, let fallback, let power, let multiply):
            value = parameters[name].map { Foundation.pow($0 * multiply, power) } ?? fallback
        case .screenDivide(let name, let fallback):
            let divisor = parameters[name] ?? fallback
            guard divisor > 0 else { throw GraphDiagnostic.unsupported("invalid screen divisor \(name)") }
            value = (Double(screen) / divisor).rounded()
        }
        guard value.isFinite, value >= 1, value <= 16_384 else {
            throw GraphDiagnostic.unsupported("resolved texture dimension \(value) exceeds device subset")
        }
        return max(1, Int(value.rounded(.down)))
    }
}

extension GraphValue {
    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
