import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct WormTracerTests {
    private func fixture() throws -> [String:Any] {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try #require(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("parity/worm-traces.json"))) as? [String:Any])
    }
    @Test func seededGeneratorMatchesJavaScriptDoubleArithmetic() throws {
        for item in try #require(fixture()["rng"] as? [[String:Any]]) {
            let seed = try #require(item["seed"] as? Double)
            var integers = WormRNG(seed:seed), floats = WormRNG(seed:seed), normals = WormRNG(seed:seed)
            for expected in try #require(item["next"] as? [UInt32]) { #expect(integers.next() == expected) }
            for expected in try #require(item["float"] as? [Double]) { #expect(abs(floats.float() - expected) < 1e-15) }
            for expected in try #require(item["normal"] as? [Double]) {
                #expect(abs(normals.normal(mean:0.25,deviation:1.5) - expected) < 1e-12)
            }
        }
    }
    @Test func orderedStrokeGeometryMatchesSource() throws {
        for item in try #require(fixture()["traces"] as? [[String:Any]]) {
            let spec = try #require(item["options"] as? [String:Any])
            func number(_ key:String) throws -> Double { try #require(spec[key] as? Double) }
            let options = try WormOptions(width:Int(number("width")),height:Int(number("height")),seed:number("seed"),
                density:number("density"),kink:number("kink"),stride:number("stride"),strideDeviation:number("strideDeviation"),
                duration:number("duration"),flowFrequency:number("flowFreq"),lineWidth:number("lineWidth"),
                behavior:#require(spec["behavior"] as? String))
            let model = try #require(spec["colorModel"] as? String)
            var segments: [WormSegment] = []
            try WormTracer.trace(options,color:{ rng,_ in
                switch model {
                case "fibers": return WormColor(red:floor(rng.float() * 200 + 55),green:floor(rng.float() * 200 + 55),blue:floor(rng.float() * 200 + 55),alpha:0.5)
                case "scratches": return WormColor(red:255,green:255,blue:255,alpha:1)
                case "strayHair": return WormColor(red:floor(rng.float() * 30),green:floor(rng.float() * 30),blue:floor(rng.float() * 30),alpha:0.666)
                case "variable": return WormColor(red:floor(rng.float() * 256),green:floor(rng.float() * 256),blue:floor(rng.float() * 256),alpha:0.25 + 0.75 * rng.float())
                default: return WormColor(red:223,green:17,blue:41,alpha:0.75)
                }
            },emit:{segments.append($0)})
            #expect(segments.count == item["segmentCount"] as? Int)
            let events = try #require(item["events"] as? [[Any]])
            let starts = events.filter {$0[0] as? String == "moveTo"}
            let ends = events.filter {$0[0] as? String == "lineTo"}
            let colors = events.filter {$0[0] as? String == "strokeStyle"}
            for (index,segment) in segments.enumerated() {
                let expected = try [#require(starts[index][1] as? Double),#require(starts[index][2] as? Double),
                                    #require(ends[index][1] as? Double),#require(ends[index][2] as? Double)]
                for (actual,value) in zip([segment.x,segment.y,segment.endX,segment.endY],expected) { #expect(abs(actual-value) < 1e-11) }
                let css = try #require(colors[index][1] as? String)
                let rgba = css.dropFirst(5).dropLast().split(separator:",").map {Double($0.trimmingCharacters(in:.whitespaces))!}
                for (actual,value) in zip([segment.color.red,segment.color.green,segment.color.blue,segment.color.alpha],rgba) {
                    #expect(abs(actual-value) < 1e-12)
                }
            }
        }
    }
    @Test func overlayPreparationIsDeterministicAndBinary() throws {
        let size = try RenderSize(width:65,height:33)
        for kind in [BuiltinOverlayKind.fibers,.scratches,.strayHair] {
            let a = try BuiltinOverlay.render(kind,size:size,seed:7)
            let b = try BuiltinOverlay.render(kind,size:size,seed:7)
            #expect(a.rgba == b.rgba)
            #expect(a.rgba.count == 65 * 33 * 4)
            #expect(a.rgba.contains {$0 != 0})
        }
    }
}
