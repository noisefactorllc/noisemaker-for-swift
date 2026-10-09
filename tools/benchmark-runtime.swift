import Foundation
import AppKit
import Metal
@testable import Noisemaker

func elapsed(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = try body()
    return (result, elapsed(start))
}
func frame(_ index: Int) -> FrameState {
    FrameState(time: Double(index) / 60, delta: 1.0 / 60, frameIndex: UInt64(index))
}
func readback(_ texture: MTLTexture, size: RenderSize,
              device: MTLDevice, queue: MTLCommandQueue) throws -> [String: Any] {
    let bytesPerPixel: Int
    switch texture.pixelFormat {
    case .rgba16Float: bytesPerPixel = 8
    case .rgba32Float: bytesPerPixel = 16
    case .rgba8Unorm, .bgra8Unorm: bytesPerPixel = 4
    default: throw GraphDiagnostic.unsupported("benchmark readback format")
    }
    let rowBytes = ((size.width * bytesPerPixel + 255) / 256) * 256
    let start = DispatchTime.now().uptimeNanoseconds
    guard let buffer = device.makeBuffer(length: rowBytes * size.height, options: .storageModeShared),
          let command = queue.makeCommandBuffer(),
          let blit = command.makeBlitCommandEncoder() else {
        throw GraphDiagnostic.missing("benchmark readback")
    }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
              to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
              destinationBytesPerImage: rowBytes * size.height)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw error }
    guard command.status == .completed else {
        throw GraphDiagnostic.invalid("benchmark readback did not complete")
    }
    var checksum: UInt8 = 0
    let pointer = buffer.contents().assumingMemoryBound(to: UInt8.self)
    for offset in stride(from: 0, to: buffer.length, by: 4096) { checksum ^= pointer[offset] }
    return ["wallMS": elapsed(start),
            "gpuMS": (command.gpuEndTime - command.gpuStartTime) * 1000,
            "bufferBytes": buffer.allocatedSize, "checksum": Int(checksum)]
}
func synchronizedFrame(renderer: NoisemakerRenderer, index: Int,
                       device: MTLDevice, queue: MTLCommandQueue,
                       probe: RuntimeBenchmarkProbe) throws -> ([String: Any], OutputLease) {
    _ = probe.drain()
    let allocatedBefore = device.currentAllocatedSize
    guard let command = queue.makeCommandBuffer() else {
        throw GraphDiagnostic.missing("benchmark command")
    }
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let (output, encodeMS) = try timed {
        try renderer.encode(frame: frame(index), into: command)
    }
    let allocatedAfterEncode = device.currentAllocatedSize
    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw error }
    guard command.status == .completed else {
        throw GraphDiagnostic.invalid("benchmark command did not complete")
    }
    let sample: [String: Any] = [
        "frameIndex": index, "cpuEncodeMS": encodeMS,
        "gpuExecutionMS": (command.gpuEndTime - command.gpuStartTime) * 1000,
        "synchronizedWallMS": elapsed(wallStart),
        "allocatedBeforeBytes": allocatedBefore,
        "allocatedAfterEncodeBytes": allocatedAfterEncode,
        "allocatedAfterCompletionBytes": device.currentAllocatedSize,
        "runtimeEvents": probe.drain()
    ]
    return (sample, output)
}

let args = CommandLine.arguments
precondition(args.count >= 8,
    "usage: benchmark source.dsl width height output.json frames|sustained|resize|inflight warmup measured [resize-sequence]")
let source = try String(contentsOfFile: args[1], encoding: .utf8)
let size = try RenderSize(width: Int(args[2])!, height: Int(args[3])!)
let mode = args[5]
let warmupFrames = Int(args[6])!
let measuredFrames = Int(args[7])!
precondition(warmupFrames >= 0 && measuredFrames > 0)
guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    throw NSError(domain: "NoisemakerBenchmark", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Metal device unavailable"])
}
let probe = RuntimeBenchmarkProbe()
RuntimeBenchmarkProbe.install(probe)
defer { RuntimeBenchmarkProbe.install(nil) }
let allocatedBefore = device.currentAllocatedSize
let (compiler, catalogMS) = try timed { try NoisemakerCompiler() }
let (graph, dslCompileMS) = try timed { try compiler.compile(source: source) }
let compileEvents = probe.drain()
var renderer: NoisemakerRenderer? = nil
let (_, coldPreparationMS) = try timed {
    renderer = try NoisemakerRenderer(device: device, graph: graph, size: size)
}
let coldEvents = probe.drain()
var warm: NoisemakerRenderer?
let (_, warmPreparationMS) = try timed {
    warm = try NoisemakerRenderer(device: device, graph: graph, size: size)
}
let warmEvents = probe.drain()
warm = nil
let drawModes = graph.passes.compactMap { $0.raw.field("drawMode")?.stringValue }
var rawFrames: [[String: Any]] = []
var extra: [String: Any] = [:]

switch mode {
case "frames", "sustained":
    guard let renderer else { throw GraphDiagnostic.missing("benchmark renderer") }
    let count = warmupFrames + measuredFrames
    for index in 0..<count {
        try autoreleasepool {
            let (sample, output) = try synchronizedFrame(renderer: renderer, index: index,
                device: device, queue: queue, probe: probe)
            if index >= warmupFrames { rawFrames.append(sample) }
            if index == count - 1 {
                extra["readback"] = try readback(output.texture, size: size,
                    device: device, queue: queue)
            }
        }
        if index >= warmupFrames {
            rawFrames[rawFrames.count - 1]["allocatedAfterScopeBytes"] = device.currentAllocatedSize
        }
    }
    if mode == "sustained" {
        let allocated = rawFrames.compactMap { $0["allocatedAfterScopeBytes"] as? Int }
        let newTextures = rawFrames.reduce(0) { total, sample in
            let events = sample["runtimeEvents"] as? [String: [Double]] ?? [:]
            return total + (events["texturePoolAllocationCount"]?.count ?? 0)
        }
        guard allocated.count == measuredFrames, newTextures == 0 else {
            throw GraphDiagnostic.invalid("sustained benchmark allocated a new transient texture after warmup")
        }
        extra["sustainedMemoryEvidence"] = [
            "driverAllocatedFirstBytes": allocated.first ?? 0,
            "driverAllocatedLastBytes": allocated.last ?? 0,
            "driverAllocatedPeakBytes": allocated.max() ?? 0,
            "driverAllocatedFloorBytes": allocated.min() ?? 0,
            "transientTextureAllocationsAfterWarmup": newTextures,
            "driverAllocationIsSeparateFromRuntimeTextureCounts": true
        ] as [String: Any]
    }
case "resize":
    guard args.count == 9 else { throw GraphDiagnostic.invalid("benchmark resize sequence") }
    guard var current = renderer else { throw GraphDiagnostic.missing("benchmark renderer") }
    renderer = nil
    let seed = try autoreleasepool { () throws -> [String: Any] in
        let (sample, _) = try synchronizedFrame(renderer: current, index: 0,
            device: device, queue: queue, probe: probe)
        return sample
    }
    extra["resizeSeedFrame"] = seed
    var transitions: [[String: Any]] = []
    var index = 1
    for token in args[8].split(separator: ",") {
        let dimensions = token.split(separator: "x")
        guard dimensions.count == 2, let width = Int(dimensions[0]),
              let height = Int(dimensions[1]) else {
            throw GraphDiagnostic.invalid("benchmark resize dimension")
        }
        let transition = try autoreleasepool { () throws -> [String: Any] in
            let target = try RenderSize(width: width, height: height)
            let before = device.currentAllocatedSize
            _ = probe.drain()
            let (replacement, prepareMS) = try timed {
                try NoisemakerRenderer(device: device, graph: graph, size: target)
            }
            let (_, adoptMS) = try timed { try replacement.adoptFeedback(from: current) }
            current = replacement
            let preparationEvents = probe.drain()
            let (sample, output) = try synchronizedFrame(renderer: current, index: index,
                device: device, queue: queue, probe: probe)
            let capture = try readback(output.texture, size: target, device: device, queue: queue)
            return ["width": width, "height": height, "prepareMS": prepareMS,
                "adoptFeedbackMS": adoptMS, "allocatedBeforeBytes": before,
                "allocatedAfterCompletionBytes": device.currentAllocatedSize,
                "preparationEvents": preparationEvents, "frame": sample,
                "readback": capture]
        }
        var released = transition
        released["allocatedAfterScopeBytes"] = device.currentAllocatedSize
        transitions.append(released)
        index += 1
    }
    extra["transitions"] = transitions
case "inflight":
    guard let renderer else { throw GraphDiagnostic.missing("benchmark renderer") }
    var batches: [[String: Any]] = []
    for batch in 0..<measuredFrames {
        let sample = try autoreleasepool { () throws -> [String: Any] in
            _ = probe.drain()
            let before = device.currentAllocatedSize
            var submissions: [FrameSubmission] = []
            var submitted: [[String: Any]] = []
            for slot in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                let submission = try renderer.render(frame: frame(batch * 3 + slot))
                submissions.append(submission)
                let active = submissions.filter {
                    $0.commandBuffer.status != .completed && $0.commandBuffer.status != .error
                }.count
                submitted.append(["slot": slot, "submitWallMS": elapsed(start),
                    "observedOutstanding": active, "allocatedBytes": device.currentAllocatedSize])
            }
            for submission in submissions {
                submission.commandBuffer.waitUntilCompleted()
                if let error = submission.commandBuffer.error { throw error }
                guard submission.commandBuffer.status == .completed else {
                    throw GraphDiagnostic.invalid("benchmark in-flight command did not complete")
                }
            }
            return ["batch": batch, "allocatedBeforeBytes": before,
                "allocatedAfterCompletionBytes": device.currentAllocatedSize,
                "submitted": submitted, "runtimeEvents": probe.drain()]
        }
        var released = sample
        released["allocatedAfterReleaseBytes"] = device.currentAllocatedSize
        batches.append(released)
    }
    extra["batches"] = batches
default:
    throw GraphDiagnostic.invalid("benchmark mode")
}
let report: [String: Any] = [
    "schemaVersion": 2, "mode": mode, "device": device.name,
    "deviceRegistryID": device.registryID,
    "recommendedMaxWorkingSetBytes": device.recommendedMaxWorkingSetSize,
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "width": size.width, "height": size.height,
    "passes": graph.passes.count, "drawModes": drawModes,
    "protocol": ["warmupFrames": warmupFrames, "measuredFrames": measuredFrames,
                 "timeStep": 1.0 / 60, "delta": 1.0 / 60,
                 "freshProcess": true, "synchronizeEachFrame": mode != "inflight",
                 "maximumSubmittedFramesPerBatch": mode == "inflight" ? 3 : 1] as [String: Any],
    "catalogLoadMS": catalogMS, "dslCompileMS": dslCompileMS,
    "compileEvents": compileEvents, "coldPreparationMS": coldPreparationMS,
    "coldPreparationEvents": coldEvents, "warmPreparationMS": warmPreparationMS,
    "warmPreparationEvents": warmEvents, "rawFrames": rawFrames,
    "deviceAllocatedBeforeBytes": allocatedBefore,
    "deviceAllocatedAfterBytes": device.currentAllocatedSize,
    "allocationScope": "Runtime counters cover TexturePool, FeedbackState, NoisemakerRenderer and BufferToTextureBridge Metal texture/buffer calls; deviceAllocated samples include driver and cache resources.",
    "extra": extra
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: args[4]))
print("BENCHMARK \(mode) \(size.width)x\(size.height) samples=\(rawFrames.count)")
