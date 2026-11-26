import Foundation
import Noisemaker

// CanvasRenderer supplies normalized loop time; Pipeline derives the delta.
struct FrameClock {
    let duration: TimeInterval
    private var origin: TimeInterval?
    private var lastTime: TimeInterval?
    init(duration: TimeInterval = 10) throws {
        guard duration.isFinite, duration > 0 else {
            throw GraphDiagnostic.invalid("loop duration must be finite and positive")
        }
        self.duration = duration
    }
    mutating func next(at uptime: TimeInterval, index: UInt64) -> FrameState {
        let start = origin ?? uptime
        origin = start
        let time = max(0, uptime - start).truncatingRemainder(dividingBy: duration) / duration
        let difference = lastTime.map { time - $0 } ?? 0
        let delta = difference < 0 ? difference + 1 : difference
        lastTime = time
        return FrameState(time: time, delta: delta, frameIndex: index)
    }
    mutating func reset() { origin = nil; lastTime = nil }
}
