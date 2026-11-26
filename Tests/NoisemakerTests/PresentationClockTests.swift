import Testing
@testable import NoisemakerMetalKit

struct PresentationClockTests {
    @Test func normalizedTimeAndWrapDeltaMatchCanvasPipeline() throws {
        var clock = try FrameClock()
        let initial = clock.next(at: 100, index: 0)
        #expect(initial.time == 0 && initial.delta == 0)
        let first = clock.next(at: 101, index: 1)
        #expect(first.time == 0.1 && first.delta == 0.1)
        let later = clock.next(at: 109.5, index: 2)
        #expect(later.time == 0.95 && later.delta == 0.85)
        let wrapped = clock.next(at: 110, index: 3)
        #expect(wrapped.time == 0)
        #expect(abs(wrapped.delta - 0.05) < 1e-12)
        let afterWrap = clock.next(at: 110.5, index: 4)
        #expect(abs(afterWrap.delta - 0.05) < 1e-12)
        clock.reset()
        let reset = clock.next(at: 200, index: 0)
        #expect(reset.time == 0 && reset.delta == 0)
        #expect(throws: (any Error).self) { _ = try FrameClock(duration: 0) }
    }
}
