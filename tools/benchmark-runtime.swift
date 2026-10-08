import Foundation
import AppKit
import Metal
import Noisemaker

// Standalone measurement executable linked by benchmark-runtime.py. Every
// invocation starts a new process; the GPU is synchronized only for measurement.
func milliseconds(_ body:() throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
}
func distribution(_ values:[Double]) -> [String:Double] {
    let sorted = values.sorted()
    return ["minimum":sorted.first ?? 0,"median":sorted[sorted.count/2],
            "p95":sorted[min(sorted.count-1,Int(ceil(Double(sorted.count)*0.95))-1)],
            "maximum":sorted.last ?? 0]
}
let args = CommandLine.arguments
precondition(args.count == 5,"usage: benchmark source.dsl width height output.json")
let source = try String(contentsOfFile:args[1],encoding:.utf8)
let size = try RenderSize(width:Int(args[2])!,height:Int(args[3])!)
guard let device = MTLCreateSystemDefaultDevice(),let queue = device.makeCommandQueue() else {
    throw NSError(domain:"NoisemakerBenchmark",code:1,userInfo:[NSLocalizedDescriptionKey:"Metal device unavailable"])
}
let before = device.currentAllocatedSize
var compiler:NoisemakerCompiler!
let catalogMS = try milliseconds {compiler = try NoisemakerCompiler()}
var graph:RenderGraph!
let compilerMS = try milliseconds {graph = try compiler.compile(source:source)}
var renderer:NoisemakerRenderer!
let coldPreparationMS = try milliseconds {renderer = try NoisemakerRenderer(device:device,graph:graph,size:size)}
var warm:NoisemakerRenderer!
let warmPreparationMS = try milliseconds {warm = try NoisemakerRenderer(device:device,graph:graph,size:size)}
warm = nil
var cpu:[Double] = [],gpu:[Double] = [],wall:[Double] = []
var finalOutput:OutputLease!
for index in 0..<20 {
    try autoreleasepool {
        guard let command = queue.makeCommandBuffer() else {throw GraphDiagnostic.missing("benchmark command")}
        var output:OutputLease!
        let wallStart = DispatchTime.now().uptimeNanoseconds
        let encodeMS = try milliseconds {
            output = try renderer.encode(frame:FrameState(time:Double(index)/60,delta:1.0/60,frameIndex:UInt64(index)),into:command)
        }
        command.commit();command.waitUntilCompleted()
        if let error = command.error {throw error}
        guard command.status == .completed else {throw GraphDiagnostic.invalid("benchmark command did not complete")}
        if index >= 4 {
            cpu.append(encodeMS)
            gpu.append((command.gpuEndTime-command.gpuStartTime)*1000)
            wall.append(Double(DispatchTime.now().uptimeNanoseconds-wallStart)/1_000_000)
        }
        finalOutput = output
    }
}
let texture = finalOutput.texture
let bytesPerPixel:Int
switch texture.pixelFormat {
case .rgba16Float:bytesPerPixel=8
case .rgba32Float:bytesPerPixel=16
case .rgba8Unorm,.bgra8Unorm:bytesPerPixel=4
default:throw GraphDiagnostic.unsupported("benchmark readback format")
}
let rowBytes = ((size.width*bytesPerPixel+255)/256)*256
var readbackGPU:Double = 0
let readbackMS = try milliseconds {
    guard let buffer = device.makeBuffer(length:rowBytes*size.height,options:.storageModeShared),
          let command = queue.makeCommandBuffer(),let blit = command.makeBlitCommandEncoder() else {
        throw GraphDiagnostic.missing("benchmark readback")
    }
    blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
              sourceSize:MTLSize(width:size.width,height:size.height,depth:1),to:buffer,destinationOffset:0,
              destinationBytesPerRow:rowBytes,destinationBytesPerImage:rowBytes*size.height)
    blit.endEncoding();command.commit();command.waitUntilCompleted()
    if let error = command.error {throw error}
    guard command.status == .completed else {throw GraphDiagnostic.invalid("benchmark readback did not complete")}
    readbackGPU = (command.gpuEndTime-command.gpuStartTime)*1000
    // Touch completed host memory so this measures usable readback, not submission.
    var checksum:UInt8 = 0
    let pointer = buffer.contents().assumingMemoryBound(to:UInt8.self)
    for offset in stride(from:0,to:buffer.length,by:4096) {checksum ^= pointer[offset]}
    if checksum == 255 {fputs("readback-checksum=255\n",stderr)}
}
let after = device.currentAllocatedSize
let report:[String:Any] = ["schemaVersion":1,"device":device.name,"os":ProcessInfo.processInfo.operatingSystemVersionString,
    "width":size.width,"height":size.height,"passes":graph.passes.count,
    "protocol":["warmupFrames":4,"measuredFrames":16,"timeStep":1.0/60,"delta":1.0/60,"freshProcess":true],
    "catalogLoadMS":catalogMS,"dslCompileMS":compilerMS,"coldPreparationMS":coldPreparationMS,
    "warmPreparationMS":warmPreparationMS,"cpuEncodeMS":distribution(cpu),"gpuExecutionMS":distribution(gpu),
    "synchronizedFrameMS":distribution(wall),"readbackWallMS":readbackMS,"readbackGpuMS":readbackGPU,
    "deviceAllocatedBeforeBytes":before,"deviceAllocatedAfterBytes":after,
    "note":"Device allocation includes driver resources and process caches; CPU encode excludes command creation and completion waits."]
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[4]))
print("BENCHMARK \(size.width)x\(size.height) cpuMedianMS=\(distribution(cpu)["median"]!) gpuMedianMS=\(distribution(gpu)["median"]!)")
