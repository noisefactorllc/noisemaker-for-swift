import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized) struct ResourceAllocatorTests {
    @Test func lockedUpstreamCaseAllocations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"]
            .map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/reference")
        let directory = reference.appendingPathComponent("cases")
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        #expect(files.count >= 10)
        for file in files {
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let stages = try #require(object["stages"] as? [String: Any])
            let expansion = try GraphValue.decode(#require(stages["expand"]))
            let passes = try #require(expansion.field("passes")?.arrayValue)
            let expected = try GraphValue.decode(#require(stages["allocate"]))
            let actual = try ResourceAllocator.allocate(passes: passes)
            #expect(entries(actual).map { "\($0.0)=\($0.1)" } ==
                    entries(expected).map { "\($0.0)=\($0.1)" }, "\(file.lastPathComponent)")
        }
    }

    @Test func duplicateInputsReleaseOnePhysicalSlot() throws {
        let passes: [GraphValue] = [
            pass(inputs: [], outputs: [("color", "a")]),
            pass(inputs: [("one", "a"), ("two", "a")], outputs: [("color", "b")]),
            pass(inputs: [], outputs: [("color", "c")])
        ]
        let result = try ResourceAllocator.allocate(passes: passes)
        #expect(entries(result).map { $0.0 } == ["a", "b", "c"])
        #expect(entries(result).map { $0.1 } == ["phys_0", "phys_1", "phys_0"])
    }

    private func pass(inputs: [(String, String)], outputs: [(String, String)]) -> GraphValue {
        .object([
            GraphField(name: "inputs", value: .object(inputs.map { GraphField(name: $0.0, value: .string($0.1)) })),
            GraphField(name: "outputs", value: .object(outputs.map { GraphField(name: $0.0, value: .string($0.1)) }))
        ])
    }

    private func entries(_ value: GraphValue) -> [(String, String)] {
        value.mapEntries?.compactMap { item in
            guard let key = item.key.stringValue, let physical = item.value.stringValue else { return nil }
            return (key, physical)
        } ?? []
    }
}
