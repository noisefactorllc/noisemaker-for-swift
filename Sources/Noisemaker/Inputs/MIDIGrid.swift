import Foundation
import Metal

/// The source runtime uploads one RGBA32Float texel for each MIDI note and channel.
/// Columns are notes 0...127 and rows are channels 1...16.
public enum MIDIGrid {
    public static let width = 128
    public static let height = 16

    public static func pixels(snapshot: MIDIInputSnapshot?) throws -> Data {
        var values = [Float](repeating: 0, count: width * height * 4)
        if let snapshot {
            for (channelNumber, channel) in snapshot.aggregate.channels {
                guard (1...height).contains(channelNumber) else {
                    throw GraphDiagnostic.invalid("MIDI grid channel must be 1...16")
                }
                var seen = Set<Int>()
                for note in channel.heldNotes {
                    guard note.key.isFinite, note.key >= 0, note.key < Double(width),
                          note.key == note.key.rounded(.towardZero),
                          note.velocity.isFinite, note.velocity >= 0, note.velocity <= 127,
                          note.velocity == note.velocity.rounded(.towardZero),
                          seen.insert(Int(note.key)).inserted else {
                        throw GraphDiagnostic.invalid("MIDI grid note or velocity is invalid")
                    }
                    let offset = ((channelNumber - 1) * width + Int(note.key)) * 4
                    if note.velocity > 0 {
                        values[offset] = Float(note.velocity / 127)
                        values[offset + 1] = 1
                    }
                }
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }

    public static func texture(device: MTLDevice,
                               snapshot: MIDIInputSnapshot?) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("Metal MIDI note grid")
        }
        let data = try pixels(snapshot: snapshot)
        data.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: width * 16)
        }
        texture.label = "midiNoteGrid"
        return texture
    }

    /// Replays source-authored MIDI message sidecars into a host snapshot.
    /// This adapter supports note on/off messages; other message types require
    /// a richer host MIDI state before they can affect the grid.
    public static func snapshot(messages: [[Int]]) throws -> MIDIInputSnapshot {
        var notes: [Int: [Int: Int]] = [:]
        for message in messages {
            guard message.count == 3,
                  message.allSatisfy({ (0...255).contains($0) }),
                  (0...127).contains(message[1]),
                  (0...127).contains(message[2]) else {
                throw GraphDiagnostic.invalid("MIDI sidecar message must be three valid bytes")
            }
            let kind = message[0] & 0xf0
            guard kind == 0x80 || kind == 0x90 else {
                throw GraphDiagnostic.unsupported("MIDI sidecar message type \(kind)")
            }
            let channel = (message[0] & 0x0f) + 1
            if kind == 0x90 && message[2] > 0 {
                notes[channel, default: [:]][message[1]] = message[2]
            } else {
                notes[channel]?[message[1]] = nil
            }
        }
        let channels = notes.mapValues { keys -> MIDIChannelSnapshot in
            MIDIChannelSnapshot(heldNotes: keys.sorted(by: { $0.key < $1.key }).map {
                MIDINoteSnapshot(key: Double($0.key), velocity: Double($0.value),
                    time: 0, order: 0)
            })
        }
        return MIDIInputSnapshot(aggregate: MIDIStateSnapshot(channels: channels))
    }
}
