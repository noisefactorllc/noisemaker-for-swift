import Foundation
import Noisemaker

let args = CommandLine.arguments
precondition(args.count == 3,"usage: measure-translations programs.json output-directory")
let variants = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[1]))) as! [[String:Any]]
let output = URL(fileURLWithPath:args[2])
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let bindingPattern = try NSRegularExpression(pattern:#"@group\(\s*(\d+)\s*\)\s*@binding\(\s*(\d+)\s*\)\s*var(?:<([^>]+)>)?\s+(\w+)\s*:\s*([^;]+);"#)
let entryPattern = try NSRegularExpression(pattern:#"@(vertex|fragment|compute)\b[^@]*(?:@workgroup_size\([^)]*\)\s*)?fn\s+(\w+)"#)
let commentPattern = try NSRegularExpression(pattern:#"(?s)/\*.*?\*/|//[^\n]*"#)
let translator = ShaderTranslator()
var records:[[String:Any]] = [], mslBytes = 0, coldMS:Double = 0, warmMS:Double = 0
func elapsed(_ block:() throws -> Void) rethrows -> Double {
 let start = DispatchTime.now().uptimeNanoseconds; try block()
 return Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
}
for item in variants {
 let wgsl = item["wgsl"] as! String, hash = item["sha256"] as! String
 let clean = commentPattern.stringByReplacingMatches(in:wgsl,range:NSRange(location:0,length:(wgsl as NSString).length),withTemplate:" ")
 let ns = clean as NSString
 var bindings:[TintBinding] = [], sizes:[TintBufferSize] = []
 var buffer:UInt32=0, texture:UInt32=0, sampler:UInt32=0
 for match in bindingPattern.matches(in:clean,range:NSRange(location:0,length:ns.length)) {
  func text(_ group:Int)->String {match.range(at:group).location == NSNotFound ? "" : ns.substring(with:match.range(at:group))}
  let group = UInt32(text(1))!, binding = UInt32(text(2))!
  let address = text(3).trimmingCharacters(in:.whitespaces), type = text(5).trimmingCharacters(in:.whitespaces)
  let kind:TintBindingKind, slot:UInt32
  if address == "uniform" {kind = .uniform;slot=buffer;buffer+=1}
  else if address.hasPrefix("storage") {
   kind = .storage;slot=buffer;buffer+=1
   sizes.append(TintBufferSize(group:group,binding:binding,index:UInt32(sizes.count)))
  } else if type.hasPrefix("texture_storage") {kind = .storageTexture;slot=texture;texture+=1}
  else if type.hasPrefix("texture_") {kind = .texture;slot=texture;texture+=1}
  else {kind = .sampler;slot=sampler;sampler+=1}
  bindings.append(TintBinding(group:group,binding:binding,kind:kind,slot:slot))
 }
 let entries = entryPattern.matches(in:clean,range:NSRange(location:0,length:ns.length))
 if entries.isEmpty {records.append(["sha256":hash,"status":"failure","error":"no shader entries found"])}
 for entry in entries {
  let name = ns.substring(with:entry.range(at:2)), stageName = ns.substring(with:entry.range(at:1))
  let stage:TintStage = stageName == "vertex" ? .vertex : stageName == "fragment" ? .fragment : .compute
  do {
   var result:TintTranslation!
   let cold = try elapsed {result = try translator.translate(wgsl:wgsl,entryPoint:name,stage:stage,bindings:bindings,
       bufferSizes:sizes,bufferSizesOffset:sizes.isEmpty ? nil : 0)}
   let warm = try elapsed {
    let repeatResult = try translator.translate(wgsl:wgsl,entryPoint:name,stage:stage,bindings:bindings,
       bufferSizes:sizes,bufferSizesOffset:sizes.isEmpty ? nil : 0)
    precondition(repeatResult.source == result.source)
   }
   let bytes = result.source.utf8.count
   try result.source.write(to:output.appendingPathComponent("\(hash)-\(name).metal"),atomically:true,encoding:.utf8)
   records.append(["sha256":hash,"entry":name,"stage":stageName,"status":"ok","mslBytes":bytes,"coldMS":cold,"warmMS":warm])
   mslBytes+=bytes;coldMS+=cold;warmMS+=warm
  } catch {records.append(["sha256":hash,"entry":name,"stage":stageName,"status":"failure","error":String(describing:error)])}
 }
}
let failures = records.filter {$0["status"] as? String == "failure"}.count
let report:[String:Any] = ["schemaVersion":1,"variants":variants.count,"entries":records.count,"failures":failures,
 "mslBytes":mslBytes,"coldTranslationTotalMS":coldMS,"warmTranslationTotalMS":warmMS,"records":records]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("translation-measurement.json"))
print("TRANSLATION entries=\(records.count) failures=\(failures) mslBytes=\(mslBytes) coldMS=\(coldMS) warmMS=\(warmMS)")
if failures > 0 {exit(1)}
