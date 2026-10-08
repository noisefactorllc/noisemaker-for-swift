import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct SurfaceTests {
    @Test func testSeedRepeatAndNextFrameMatchLockedUpstream() throws {
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"].map(URL.init(fileURLWithPath:)) ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/reference")
        let oracle = try requireValue(JSONSerialization.jsonObject(with: Data(contentsOf: reference.appendingPathComponent("surfaces.json"))) as? [String: Any])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lock = try requireValue(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("parity/reference.json"))) as? [String: String])
        expectEqual(oracle["reference"] as? [String: String], lock)
        let cases = try requireValue(oracle["cases"] as? [[String: Any]])
        expectEqual(cases.count, 16)
        for fixture in cases {
            let surface = try requireValue(fixture["surface"] as? String)
            let count = try requireValue(fixture["repeat"] as? Int)
            let logical = "global_" + surface
            var manager = try SurfaceManager(surfaces: [surface])
            for frame in try requireValue(fixture["frames"] as? [[String: Any]]) {
                manager.beginFrame()
                let steps = try requireValue(frame["steps"] as? [[String: String]])
                for (index, step) in steps.enumerated() {
                    expectEqual(try manager.readTarget(logical), step["read"])
                    expectEqual(try manager.writeTarget(logical), step["write"])
                    try manager.advance(outputs: [logical], repeated: index > 0 && count > 1)
                }
                expectEqual(try manager.readTarget(logical), frame["finalRead"] as? String)
                try manager.finishFrame()
                manager.beginFrame()
                expectEqual(try manager.readTarget(logical), frame["nextRead"] as? String)
                expectEqual(try manager.writeTarget(logical), frame["nextWrite"] as? String)
            }
        }
    }

    @Test func testInvalidSurfaceTransitionDoesNotPartiallyAdvance() throws {
        var manager = try SurfaceManager(surfaces: ["state", "o0"])
        expectThrows(try manager.finishFrame())
        expectThrows(try manager.advance(outputs: ["global_state"], repeated: false))
        manager.beginFrame()
        let initial = try manager.readTarget("global_state")
        expectThrows(try manager.advance(outputs: ["global_state", "global_state"], repeated: false))
        expectThrows(try manager.advance(outputs: ["global_state", "global_missing"], repeated: false))
        expectEqual(try manager.readTarget("global_state"), initial)
        try manager.finishFrame()
        expectThrows(try manager.finishFrame())
    }

    @Test func testSnapshotIsolationAndIndependentSurfaces() throws {
        var original = try SurfaceManager(surfaces: ["state", "o0"])
        original.beginFrame()
        var prepared = original
        try prepared.advance(outputs: ["global_state"], repeated: false)
        expectNotEqual(try prepared.readTarget("global_state"), try original.readTarget("global_state"))
        expectEqual(try prepared.readTarget("global_o0"), try original.readTarget("global_o0"))
        expectEqual(try prepared.readTarget("node_0_out"), "node_0_out")
        expectThrows(try prepared.readTarget("global_missing"))
        expectThrows(try SurfaceManager(surfaces: ["state", "state"]))
    }
}
