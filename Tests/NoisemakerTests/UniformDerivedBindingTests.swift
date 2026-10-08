import CryptoKit
import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized) struct UniformDerivedBindingTests {
    @Test func sourceDirectBindingsDefaultAndCoerceExactBytes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"]
            .map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/reference")
        let oracle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            reference.appendingPathComponent("uniforms.json"))) as? [String: Any])
        let cases = try #require(oracle["directCases"] as? [[String: Any]])
        #expect(cases.count == 14)
        var failures: [String] = []
        for item in cases {
            let label = try #require(item["name"] as? String)
            let wgsl = try #require(item["wgsl"] as? String)
            let type = try #require(item["type"] as? String)
            let rawValues = try #require(item["values"])
            let fields = try #require(GraphValue.decode(rawValues).objectFields)
            let expected = try #require(item["bytes"] as? [UInt8])
            do {
                let plan = try UniformPlan.parse(type: type, wgsl: wgsl,
                    layout: nil, program: label)
                let pass = GraphPass(id: label, program: label, raw: .object([]),
                    inputs: [], outputs: [], uniforms: fields,
                    entryPoint: "main", repeatCount: 1)
                let encoded = try plan.encode(name: "value", pass: pass,
                    frame: FrameState(time: 0.25, delta: 0, frameIndex: 7),
                    size: RenderSize(width: 257, height: 129))
                let padded = Array(encoded) + [UInt8](repeating: 0,
                    count: max(0, expected.count - encoded.count))
                if padded != expected {
                    let first = Array(zip(padded, expected)).firstIndex { $0.0 != $0.1 }
                    failures.append("\(label): actual \(encoded.count), expected \(expected.count), first byte \(first.map(String.init) ?? "length")")
                }
            } catch {
                failures.append("\(label): \(error)")
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func sourceDerivedLayoutsPackExactWebGPUBytes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"]
            .map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/reference")
        let oracle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            reference.appendingPathComponent("uniforms.json"))) as? [String: Any])
        let cases = try #require(oracle["derivedCases"] as? [[String: Any]])
        #expect(cases.count == 8)
        var failures: [String] = []
        for item in cases {
            let label = try #require(item["name"] as? String)
            let wgsl = try #require(item["wgsl"] as? String)
            let digest = SHA256.hash(data: Data(wgsl.utf8))
                .map { String(format: "%02x", $0) }.joined()
            #expect(digest == item["sourceSha256"] as? String, "\(label) source identity")
            let type = try #require(item["type"] as? String)
            let binding = try #require(item["uniformName"] as? String)
            let rawValues = try #require(item["values"])
            let fields = try #require(GraphValue.decode(rawValues).objectFields)
            let explicit: GraphValue?
            if let raw = item["explicitLayout"], !(raw is NSNull) {
                explicit = try GraphValue.decode(raw)
            } else {
                explicit = nil
            }
            do {
                let plan = try UniformPlan.parse(type: type, wgsl: wgsl,
                    layout: explicit, program: label)
                let pass = GraphPass(id: label, program: label, raw: .object([]),
                    inputs: [], outputs: [], uniforms: fields,
                    entryPoint: "main", repeatCount: 1)
                let actual = try plan.encode(name: binding, pass: pass,
                    frame: FrameState(time: 0.25, delta: 0, frameIndex: 7),
                    size: RenderSize(width: 257, height: 129))
                let expected = try #require(item["bytes"] as? [UInt8])
                let prefix = try #require(item["packedByteLength"] as? Int)
                #expect(expected.count >= prefix, "\(label) declared buffer floor")
                if Array(actual) != expected {
                    let first = Array(zip(actual, expected)).firstIndex { $0.0 != $0.1 }
                    failures.append("\(label): actual \(actual.count) expected \(expected.count), first byte \(first.map(String.init) ?? "length")")
                }
            } catch {
                failures.append("\(label): \(error)")
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
