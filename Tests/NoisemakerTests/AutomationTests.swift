import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct AutomationTests {
    @Test func sourceBoundAutomation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reference = ProcessInfo.processInfo.environment["NM_REFERENCE_EXPORT"].map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/reference")
        let oracle = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: reference.appendingPathComponent("automation.json"))) as? [String: Any])
        let lock = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("parity/reference.json"))) as? [String:String])
        #expect(oracle["reference"] as? [String:String] == lock)
        let cases = try #require(oracle["cases"] as? [[String:Any]])
        #expect(cases.count >= 600)
        for fixture in cases {
            let name = try #require(fixture["name"] as? String)
            let config = try GraphValue.decode(#require(fixture["config"]))
            let spec = try GraphValue.decode(#require(fixture["paramSpec"]))
            let inputs = try JSONDecoder().decode(AutomationInputs.self, from: JSONSerialization.data(withJSONObject: #require(fixture["inputs"])))
            let time = try #require(fixture["time"] as? Double)
            let expected = try #require(fixture["expected"] as? Double)
            let actual = try #require(AutomationEvaluator.resolve(config, time: time, parameterSpec: spec, inputs: inputs).numberValue)
            #expect(abs(actual - expected) <= 1e-10, "\(name): \(actual) != \(expected)")
            if expected == 0 { #expect((actual.sign == .minus) == (fixture["negativeZero"] as? Bool), "\(name): zero sign") }
        }
    }
    @Test func ordinaryValuesAndUndefinedCC() throws {
        let ordinary: GraphValue = .array([.number(3),.string("raw")])
        #expect(AutomationEvaluator.resolve(ordinary,time:0).sameOrderedValue(as: ordinary))
        let config = GraphValue.object([GraphField(name:"type",value:.string("Midi")),GraphField(name:"mode",value:.number(5)),
            GraphField(name:"channel",value:.number(1)),GraphField(name:"cc",value:.undefined)])
        let inputs = AutomationInputs(midi:MIDIInputSnapshot(aggregate:MIDIStateSnapshot(channels:[1:MIDIChannelSnapshot(cc:[1:127])])))
        #expect(AutomationEvaluator.resolve(config,time:0,inputs:inputs).numberValue == 1)
    }
}
