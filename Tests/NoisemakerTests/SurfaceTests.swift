import Foundation
import XCTest
@testable import Noisemaker

final class SurfaceTests: XCTestCase {
    func testSeedRepeatAndNextFrameMatchLockedUpstream() throws {
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"].map(URL.init(fileURLWithPath:)) ??
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/reference")
        let oracle = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reference.appendingPathComponent("surfaces.json"))) as? [String: Any])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lock = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("parity/reference.json"))) as? [String: String])
        XCTAssertEqual(oracle["reference"] as? [String: String], lock)
        let cases = try XCTUnwrap(oracle["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 16)
        for fixture in cases {
            let surface = try XCTUnwrap(fixture["surface"] as? String)
            let count = try XCTUnwrap(fixture["repeat"] as? Int)
            let logical = "global_" + surface
            var manager = try SurfaceManager(surfaces: [surface])
            for frame in try XCTUnwrap(fixture["frames"] as? [[String: Any]]) {
                manager.beginFrame()
                let steps = try XCTUnwrap(frame["steps"] as? [[String: String]])
                for (index, step) in steps.enumerated() {
                    XCTAssertEqual(try manager.readTarget(logical), step["read"])
                    XCTAssertEqual(try manager.writeTarget(logical), step["write"])
                    try manager.advance(outputs: [logical], repeated: index > 0 && count > 1)
                }
                XCTAssertEqual(try manager.readTarget(logical), frame["finalRead"] as? String)
                try manager.finishFrame()
                manager.beginFrame()
                XCTAssertEqual(try manager.readTarget(logical), frame["nextRead"] as? String)
                XCTAssertEqual(try manager.writeTarget(logical), frame["nextWrite"] as? String)
            }
        }
    }

    func testInvalidSurfaceTransitionDoesNotPartiallyAdvance() throws {
        var manager = try SurfaceManager(surfaces: ["state", "o0"])
        XCTAssertThrowsError(try manager.finishFrame())
        XCTAssertThrowsError(try manager.advance(outputs: ["global_state"], repeated: false))
        manager.beginFrame()
        let initial = try manager.readTarget("global_state")
        XCTAssertThrowsError(try manager.advance(outputs: ["global_state", "global_state"], repeated: false))
        XCTAssertThrowsError(try manager.advance(outputs: ["global_state", "global_missing"], repeated: false))
        XCTAssertEqual(try manager.readTarget("global_state"), initial)
        try manager.finishFrame()
        XCTAssertThrowsError(try manager.finishFrame())
    }

    func testSnapshotIsolationAndIndependentSurfaces() throws {
        var original = try SurfaceManager(surfaces: ["state", "o0"])
        original.beginFrame()
        var prepared = original
        try prepared.advance(outputs: ["global_state"], repeated: false)
        XCTAssertNotEqual(try prepared.readTarget("global_state"), try original.readTarget("global_state"))
        XCTAssertEqual(try prepared.readTarget("global_o0"), try original.readTarget("global_o0"))
        XCTAssertEqual(try prepared.readTarget("node_0_out"), "node_0_out")
        XCTAssertThrowsError(try prepared.readTarget("global_missing"))
        XCTAssertThrowsError(try SurfaceManager(surfaces: ["state", "state"]))
    }
}
