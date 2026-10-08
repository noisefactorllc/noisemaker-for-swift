import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct MIDIGridTests {
    private func component(_ data: Data, channel: Int, note: Int, component: Int) -> Float {
        let offset = (((channel - 1) * 128 + note) * 4 + component) * 4
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }

    @Test func noteMessagesPackSourceVelocityAndGateByChannel() throws {
        let snapshot = try MIDIGrid.snapshot(messages: [
            [0x90, 40, 40], [0x9f, 80, 115], [0x91, 60, 70], [0x81, 60, 0]
        ])
        let data = try MIDIGrid.pixels(snapshot: snapshot)
        expectEqual(data.count, 128 * 16 * 4 * 4)
        expectEqual(component(data, channel: 1, note: 40, component: 0), Float(40.0 / 127.0))
        expectEqual(component(data, channel: 1, note: 40, component: 1), 1)
        expectEqual(component(data, channel: 1, note: 40, component: 2), 0)
        expectEqual(component(data, channel: 1, note: 40, component: 3), 0)
        expectEqual(component(data, channel: 16, note: 80, component: 0), Float(115.0 / 127.0))
        expectEqual(component(data, channel: 16, note: 80, component: 1), 1)
        expectEqual(component(data, channel: 2, note: 60, component: 0), 0)
        expectEqual(component(data, channel: 2, note: 60, component: 1), 0)
        expectEqual(component(data, channel: 8, note: 40, component: 0), 0)
    }

    @Test func missingSnapshotIsZeroAndMalformedMessagesRefuse() throws {
        let empty = try MIDIGrid.pixels(snapshot: nil)
        expectTrue(empty.allSatisfy { $0 == 0 })
        expectThrows(try MIDIGrid.snapshot(messages: [[0x90, 128, 20]]))
        expectThrows(try MIDIGrid.snapshot(messages: [[0xb0, 4, 20]]))
        let invalid = MIDIInputSnapshot(aggregate: MIDIStateSnapshot(channels: [
            17: MIDIChannelSnapshot(heldNotes: [MIDINoteSnapshot(key: 1, velocity: 20,
                time: 0, order: 0)])
        ]))
        expectThrows(try MIDIGrid.pixels(snapshot: invalid))
    }
}
