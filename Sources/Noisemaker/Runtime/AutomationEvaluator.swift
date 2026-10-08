import Foundation

/// Native counterpart of Pipeline.resolveUniformValue. Configurations are
/// immutable value trees, so object-reference cycles cannot enter this API.
public enum AutomationEvaluator {
    private struct Range { let min: Double; let max: Double }
    private static let unit = Range(min: 0, max: 1)
    private static let rate = Range(min: -20, max: 20)
    private static let phase = Range(min: -1, max: 1)
    private static let seedRange = Range(min: 1, max: 9999)
    private static let sensitivityRange = Range(min: 0, max: 10)
    private static let tau = Double.pi * 2
    private static let rules: [([Double], [Double])] = [
        ([-0.9894009349916499,-0.9445750230732326,-0.8656312023878318,-0.755404408355003,
          -0.6178762444026438,-0.4580167776572274,-0.2816035507792589,-0.0950125098376374,
          0.0950125098376374,0.2816035507792589,0.4580167776572274,0.6178762444026438,
          0.755404408355003,0.8656312023878318,0.9445750230732326,0.9894009349916499],
         [0.0271524594117541,0.0622535239386479,0.0951585116824928,0.1246289712555339,
          0.1495959888165767,0.1691565193950025,0.1826034150449236,0.1894506104550685,
          0.1894506104550685,0.1826034150449236,0.1691565193950025,0.1495959888165767,
          0.1246289712555339,0.0951585116824928,0.0622535239386479,0.0271524594117541]),
        ([-0.9602898564975363,-0.7966664774136267,-0.525532409916329,-0.1834346424956498,
          0.1834346424956498,0.525532409916329,0.7966664774136267,0.9602898564975363],
         [0.1012285362903763,0.2223810344533745,0.3137066458778873,0.362683783378362,
          0.362683783378362,0.3137066458778873,0.2223810344533745,0.1012285362903763]),
        ([-0.8611363115940526,-0.3399810435848563,0.3399810435848563,0.8611363115940526],
         [0.3478548451374538,0.6521451548625461,0.6521451548625461,0.3478548451374538]),
        ([-0.5773502691896257,0.5773502691896257], [1,1])
    ]
    public static func isAutomation(_ value: GraphValue) -> Bool {
        let types: Set<String> = ["Oscillator", "Midi", "Audio"]
        return types.contains(value.field("type")?.stringValue ?? "") ||
            types.contains(value.field("_ast")?.field("type")?.stringValue ?? "")
    }
    public static func resolve(_ value: GraphValue, time: Double, parameterSpec: GraphValue? = nil,
                               inputs: AutomationInputs = AutomationInputs()) -> GraphValue {
        guard isAutomation(value) else { return value }
        var range: Range?
        if let low = finite(parameterSpec?.field("min")), let high = finite(parameterSpec?.field("max")) {
            range = Range(min: low, max: high)
        }
        let output = evaluate(value, time: time, range: range, inputs: inputs, depth: 0)
        if parameterSpec?.field("type")?.stringValue == "int" {
            return .number(output < 0 && output >= -0.5 ? -0.0 : floor(output + 0.5))
        }
        return .number(output)
    }
    private static func kind(_ value: GraphValue, _ type: String) -> Bool {
        value.field("type")?.stringValue == type || value.field("_ast")?.field("type")?.stringValue == type
    }
    private static func finite(_ value: GraphValue?) -> Double? {
        guard let number = value?.numberValue, number.isFinite else { return nil }
        return number
    }
    private static func truthy(_ value: GraphValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .undefined, .null: return false
        case .bool(let value): return value
        case .number(let value): return value != 0 && !value.isNaN
        case .string(let value): return !value.isEmpty
        default: return true
        }
    }
    private static func defined(_ value: GraphValue?) -> Bool { value != nil && value?.isUndefined != true }
    private static func scale(_ value: Double, _ range: Range?) -> Double {
        guard let range else { return value }
        return range.min + value * (range.max - range.min)
    }
    private static func field(_ value: GraphValue?, time: Double, range: Range, inputs: AutomationInputs,
                              depth: Int, fallback: Double) -> Double {
        if let value, isAutomation(value) { return evaluate(value, time: time, range: range, inputs: inputs, depth: depth + 1) }
        return finite(value) ?? fallback
    }
    private static func evaluate(_ value: GraphValue, time: Double, range: Range?, inputs: AutomationInputs, depth: Int) -> Double {
        guard isAutomation(value), depth <= 8 else { return scale(0, range) }
        let result: Double
        if kind(value, "Oscillator") { result = oscillator(value, time: time, inputs: inputs, depth: depth) }
        else if kind(value, "Midi") {
            let low = field(value.field("min"), time: time, range: unit, inputs: inputs, depth: depth, fallback: 0)
            let high = field(value.field("max"), time: time, range: unit, inputs: inputs, depth: depth, fallback: 1)
            let sensitivity = field(value.field("sensitivity"), time: time, range: sensitivityRange, inputs: inputs, depth: depth, fallback: 1)
            result = midi(value, inputs: inputs, low: low, high: high, sensitivity: sensitivity)
        } else if truthy(value.field("_invalid")) { result = finite(value.field("min")) ?? 0 }
        else {
            let low = field(value.field("min"), time: time, range: unit, inputs: inputs, depth: depth, fallback: 0)
            let high = field(value.field("max"), time: time, range: unit, inputs: inputs, depth: depth, fallback: 1)
            result = audio(value, inputs: inputs.audio, low: low, high: high)
        }
        return scale(result, range)
    }
    private static func oscillator(_ value: GraphValue, time: Double, inputs: AutomationInputs, depth: Int) -> Double {
        let low = field(value.field("min"), time: time, range: unit, inputs: inputs, depth: depth, fallback: 0)
        let high = field(value.field("max"), time: time, range: unit, inputs: inputs, depth: depth, fallback: 1)
        let offset = field(value.field("offset"), time: time, range: phase, inputs: inputs, depth: depth, fallback: 0)
        let seed = field(value.field("seed"), time: time, range: seedRange, inputs: inputs, depth: depth, fallback: 1)
        let phaseValue: Double
        if let speed = value.field("speed"), isAutomation(speed) {
            phaseValue = integral(speed, time: time, range: rate, inputs: inputs, depth: depth)
        } else { phaseValue = time * (finite(value.field("speed")) ?? 1) }
        let t = phaseValue + offset
        let raw: Double
        switch value.field("oscType")?.numberValue {
        case 0: raw = (1 - cos(t * tau)) * 0.5
        case 1: raw = 1 - abs((t - floor(t)) * 2 - 1)
        case 2: raw = t - floor(t)
        case 3: raw = 1 - (t - floor(t))
        case 4: raw = t - floor(t) >= 0.5 ? 1 : 0
        case 5: raw = noise(t, seed: seed)
        case 6:
            let speed = field(value.field("speed"), time: time, range: rate, inputs: inputs, depth: depth, fallback: 1)
            let px = (abs(seed.truncatingRemainder(dividingBy: 16)) + 0.5) / 16
            let py = (abs(floor(seed / 16).truncatingRemainder(dividingBy: 16)) + 0.5) / 16
            let timeNoise = noise2D(px, py, seed + 12345)
            let valueNoise = noise2D(px, py, seed)
            let scaledTime = (sin((time + offset - timeNoise) * tau) + 1) * 0.5 * speed
            raw = (sin((scaledTime - valueNoise) * tau) + 1) * 0.5
        default: raw = 0
        }
        return low + raw * (high - low)
    }
    private static func primitive(_ kind: Double, _ x: Double) -> Double {
        let whole = floor(x), fraction = x - floor(x)
        switch kind {
        case 0: return x * 0.5 - sin(x * tau) / (2 * tau)
        case 1: return whole * 0.5 + (fraction < 0.5 ? fraction * fraction : 2 * fraction - fraction * fraction - 0.5)
        case 2: return whole * 0.5 + fraction * fraction * 0.5
        case 3: return x - (whole * 0.5 + fraction * fraction * 0.5)
        case 4: return whole * 0.5 + max(0, fraction - 0.5)
        default: return 0 // JavaScript subtracts null primitives as zero.
        }
    }
    private static func integral(_ value: GraphValue, time: Double, range: Range?, inputs: AutomationInputs, depth: Int) -> Double {
        let result: Double
        let numeric = ["min", "max", "speed", "offset", "seed"].allSatisfy { finite(value.field($0)) != nil }
        if kind(value, "Oscillator"), let type = finite(value.field("oscType")), (0...4).contains(type), numeric {
            let low = finite(value.field("min"))!, high = finite(value.field("max"))!
            let speed = finite(value.field("speed"))!, offset = finite(value.field("offset"))!
            if speed == 0 { result = oscillator(value, time: 0, inputs: AutomationInputs(), depth: 0) * time }
            else {
                let raw = (primitive(type, offset + speed * time) - primitive(type, offset)) / speed
                result = low * time + (high - low) * raw
            }
        } else if (kind(value, "Midi") || kind(value, "Audio")) &&
            !(kind(value, "Midi") ? ["min", "max", "sensitivity"] : ["min", "max"]).contains(where: {
                value.field($0).map(isAutomation) ?? false
            }) {
            result = evaluate(value, time: time, range: nil, inputs: inputs, depth: depth + 1) * time
        } else {
            let rule = rules[min(depth, rules.count - 1)]
            let half = time * 0.5
            var sum = 0.0
            for index in rule.0.indices {
                sum += rule.1[index] * evaluate(value, time: half + half * rule.0[index], range: nil, inputs: inputs, depth: depth + 1)
            }
            result = half * sum
        }
        guard let range else { return result }
        return range.min * time + result * (range.max - range.min)
    }
    private static func hash(_ px: Double, _ py: Double, _ seed: Double) -> Double {
        var x = (px * 234.34 + seed).truncatingRemainder(dividingBy: 1)
        var y = (py * 435.345 + seed).truncatingRemainder(dividingBy: 1)
        if x < 0 { x += 1 }; if y < 0 { y += 1 }
        let p = x + y + (x + y) * 34.23
        return (x * y * p).truncatingRemainder(dividingBy: 1)
    }
    private static func noise2D(_ px: Double, _ py: Double, _ seed: Double) -> Double {
        let ix = floor(px), iy = floor(py)
        var fx = px - ix, fy = py - iy
        fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy, seed), b = hash(ix + 1, iy, seed)
        let c = hash(ix, iy + 1, seed), d = hash(ix + 1, iy + 1, seed)
        return a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy
    }
    private static func noise(_ time: Double, seed: Double) -> Double {
        let angle = time.truncatingRemainder(dividingBy: 1) * tau
        let x = cos(angle) * 2, y = sin(angle) * 2
        return (noise2D(x + seed, y + seed, seed) + noise2D(x + seed * 2, y + seed * 2, seed)) / 2
    }
    private static func integer(_ value: GraphValue?, from low: Int, through high: Int) -> Int? {
        guard let n = finite(value), n.rounded() == n, n >= Double(low), n <= Double(high) else { return nil }
        return Int(n)
    }
    private static func audio(_ config: GraphValue, inputs: AudioInputSnapshot?, low: Double, high: Double) -> Double {
        guard !truthy(config.field("_invalid")), let inputs else { return low }
        let ast = kind(config.field("_ast") ?? .null, "Audio") ? config.field("_ast") : config
        let selected = ["name", "id", "channel"].contains { defined(config.field($0)) || defined(ast?.field($0)) }
        var state: AudioLevels? = inputs.aggregate
        if selected {
            guard ["name", "id", "channel"].allSatisfy({ !defined(ast?.field($0)) || defined(config.field($0)) }),
                  let channel = integer(config.field("channel"), from: 1, through: 32) else { return low }
            let name = config.field("name")?.stringValue, id = config.field("id")?.stringValue
            if defined(config.field("name")) && (name == nil || name == "") { return low }
            if defined(config.field("id")) && (id == nil || id == "" || name == nil || name == "") { return low }
            if let id { state = inputs.devices.first { $0.id == id && $0.connected }?.channels[channel] }
            else if let name {
                let matches = inputs.devices.filter { $0.name == name && $0.connected }
                state = matches.count == 1 ? matches[0].channels[channel] : nil
            } else { state = inputs.defaultChannels[channel] }
        }
        guard let state else { return low }
        let raw: Double
        switch config.field("band")?.numberValue {
        case 0: raw = state.low
        case 1: raw = state.mid
        case 2: raw = state.high
        case 3: raw = state.vol
        case 4:
            guard state.rawReady else { return low }
            raw = (max(-1, min(1, state.raw)) + 1) * 0.5
        default: raw = 0
        }
        return low + max(0, min(1, raw)) * (high - low)
    }
    private static func midi(_ config: GraphValue, inputs: AutomationInputs, low: Double, high: Double, sensitivity: Double) -> Double {
        guard !truthy(config.field("_invalid")), let midi = inputs.midi else { return low }
        var state = midi.aggregate
        var scopes: [MIDIStateSnapshot] = [midi.unscoped ?? MIDIStateSnapshot()] +
            midi.ports.filter(\.connected).map(\.state)
        let name = config.field("name")?.stringValue, id = config.field("id")?.stringValue
        if let id, !id.isEmpty {
            guard let port = midi.ports.first(where: { $0.id == id && $0.connected }) else { return low }
            state = port.state; scopes = [state]
        } else if let name, !name.isEmpty {
            let ports = midi.ports.filter { $0.name == name && $0.connected }
            guard ports.count == 1 else { return low }
            state = ports[0].state; scopes = [state]
        }
        let mode = config.field("mode")?.numberValue ?? 4
        let hasZone = defined(config.field("zone"))
        let zone = integer(config.field("zone"), from: 0, through: 1)
        if hasZone && (defined(config.field("channel")) || zone == nil) { return low }
        let members = integer(config.field("members"), from: 1, through: 15)
        if defined(config.field("members")) && (!hasZone || members == nil) { return low }
        let channelNumber = integer(config.field("channel"), from: 1, through: 16)
        if !hasZone && mode >= 5 && channelNumber == nil { return low }
        var channel = state.channels[channelNumber ?? 1] ?? MIDIChannelSnapshot()
        if hasZone {
            var newest: (MIDINoteSnapshot, MIDIChannelSnapshot)?
            for scope in scopes {
                let count = members ?? (zone == 0 ? scope.lowerZoneMembers : scope.upperZoneMembers) ?? 15
                let first = zone == 0 ? 2 : 16 - count, last = zone == 0 ? 1 + count : 15
                if first <= last { for index in first...last {
                    guard let candidate = scope.channels[index] else { continue }
                    for note in candidate.heldNotes where newest == nil || note.order > newest!.0.order { newest = (note, candidate) }
                } }
            }
            guard let newest else { return low }
            channel = newest.1
            channel.key = newest.0.key; channel.velocity = newest.0.velocity; channel.time = newest.0.time; channel.gate = 1
        }
        func map(_ number: Double, _ divisor: Double = 127) -> Double { low + number / divisor * (high - low) }
        switch mode {
        case 0: return map(channel.key)
        case 1: return map(channel.gate == 1 ? channel.key : 0)
        case 2: return map(channel.gate == 1 ? channel.velocity : 0)
        case 5, 6:
            let selector = config.field("cc") ?? .number(1)
            guard let cc = integer((selector.isNull || selector.isUndefined) ? .number(1) : selector, from: 0, through: mode == 6 ? 31 : 127) else { return low }
            return map(mode == 6 ? channel.cc14[cc] ?? 0 : channel.cc[cc] ?? 0, mode == 6 ? 16383 : 127)
        case 7:
            guard let nrpn = integer(config.field("nrpn"), from: 0, through: 16382) else { return low }
            return map(channel.nrpn[nrpn] ?? 0, 16383)
        case 8: return map(channel.pitchBend, 16383)
        case 9: return map(channel.pressure)
        case 10:
            guard channel.key.isFinite, channel.key >= 0, channel.key < 128, channel.key.rounded() == channel.key else { return low }
            return map(channel.polyPressure[Int(channel.key)] ?? 0)
        default:
            guard channel.gate == 1 else { return low }
            let raw = mode == 3 ? channel.key : channel.velocity
            let decay = min(1, (inputs.wallTimeMilliseconds - channel.time) * sensitivity * 0.001)
            return map(raw * (1 - decay))
        }
    }
}
