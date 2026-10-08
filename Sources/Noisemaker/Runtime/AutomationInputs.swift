import Foundation

/// Host-fed snapshots. Capture, device permissions, and wall-clock selection
/// remain with the embedding application; evaluation does not access devices.
public struct AudioLevels: Codable, Sendable {
    public var low: Double, mid: Double, high: Double, vol: Double, raw: Double
    public var rawReady: Bool
    public init(low: Double = 0, mid: Double = 0, high: Double = 0, vol: Double = 0,
                raw: Double = 0, rawReady: Bool = false) {
        self.low = low; self.mid = mid; self.high = high; self.vol = vol
        self.raw = raw; self.rawReady = rawReady
    }
}
public struct AudioDeviceSnapshot: Codable, Sendable {
    public var id: String, name: String
    public var connected: Bool
    public var channels: [Int: AudioLevels]
    public init(id: String, name: String, connected: Bool = true, channels: [Int: AudioLevels]) {
        self.id = id; self.name = name; self.connected = connected; self.channels = channels
    }
}
public struct AudioInputSnapshot: Codable, Sendable {
    public var aggregate: AudioLevels
    public var defaultChannels: [Int: AudioLevels]
    public var devices: [AudioDeviceSnapshot]
    /// Source AudioState sample buffers: 128 normalized float32 values.
    /// Nil retains source silence defaults (waveform 0.5, spectrum 0).
    public var waveform: [Float]?
    public var spectrum: [Float]?
    public init(aggregate: AudioLevels = AudioLevels(), defaultChannels: [Int: AudioLevels] = [:],
                devices: [AudioDeviceSnapshot] = [], waveform: [Float]? = nil, spectrum: [Float]? = nil) {
        self.aggregate = aggregate; self.defaultChannels = defaultChannels; self.devices = devices
        self.waveform = waveform; self.spectrum = spectrum
    }
}
public struct MIDINoteSnapshot: Codable, Sendable {
    public var key: Double, velocity: Double, time: Double, order: Double
    public init(key: Double, velocity: Double, time: Double, order: Double) {
        self.key = key; self.velocity = velocity; self.time = time; self.order = order
    }
}
public struct MIDIChannelSnapshot: Codable, Sendable {
    public var key: Double, velocity: Double, gate: Double, time: Double
    public var pitchBend: Double, pressure: Double
    public var cc: [Int: Double], cc14: [Int: Double], nrpn: [Int: Double], polyPressure: [Int: Double]
    public var heldNotes: [MIDINoteSnapshot]
    public init(key: Double = 0, velocity: Double = 0, gate: Double = 0, time: Double = 0,
                pitchBend: Double = 8192, pressure: Double = 0,
                cc: [Int: Double] = [:], cc14: [Int: Double] = [:], nrpn: [Int: Double] = [:],
                polyPressure: [Int: Double] = [:], heldNotes: [MIDINoteSnapshot] = []) {
        self.key = key; self.velocity = velocity; self.gate = gate; self.time = time
        self.pitchBend = pitchBend; self.pressure = pressure
        self.cc = cc; self.cc14 = cc14; self.nrpn = nrpn; self.polyPressure = polyPressure
        self.heldNotes = heldNotes
    }
}
public struct MIDIStateSnapshot: Codable, Sendable {
    public var channels: [Int: MIDIChannelSnapshot]
    public var lowerZoneMembers: Int?, upperZoneMembers: Int?
    public var clockCount: Double
    public init(channels: [Int: MIDIChannelSnapshot] = [:], lowerZoneMembers: Int? = nil,
                upperZoneMembers: Int? = nil, clockCount: Double = 0) {
        self.channels = channels; self.lowerZoneMembers = lowerZoneMembers
        self.upperZoneMembers = upperZoneMembers; self.clockCount = clockCount
    }
}
public struct MIDIPortSnapshot: Codable, Sendable {
    public var id: String, name: String
    public var connected: Bool
    public var state: MIDIStateSnapshot
    public init(id: String, name: String, connected: Bool = true, state: MIDIStateSnapshot) {
        self.id = id; self.name = name; self.connected = connected; self.state = state
    }
}
public struct MIDIInputSnapshot: Codable, Sendable {
    public var aggregate: MIDIStateSnapshot
    public var unscoped: MIDIStateSnapshot?
    public var ports: [MIDIPortSnapshot]
    public init(aggregate: MIDIStateSnapshot = MIDIStateSnapshot(), unscoped: MIDIStateSnapshot? = nil,
                ports: [MIDIPortSnapshot] = []) {
        self.aggregate = aggregate; self.unscoped = unscoped; self.ports = ports
    }
}
public struct AutomationInputs: Codable, Sendable {
    public var audio: AudioInputSnapshot?
    public var midi: MIDIInputSnapshot?
    /// Same units as JavaScript Date.now(), explicitly supplied for deterministic export.
    public var wallTimeMilliseconds: Double
    public init(audio: AudioInputSnapshot? = nil, midi: MIDIInputSnapshot? = nil,
                wallTimeMilliseconds: Double = 0) {
        self.audio = audio; self.midi = midi; self.wallTimeMilliseconds = wallTimeMilliseconds
    }
}
