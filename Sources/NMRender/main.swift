import AppKit
import Foundation
import Metal
import Noisemaker

private struct Arguments {
    let graph: URL?
    let dsl: URL?
    let output: URL
    let width: Int
    let height: Int
    let time: Double
    let frames: Int
    let vertex: URL?

    init(_ input: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < input.count {
            let key = input[index]
            guard ["--graph", "--dsl", "--out", "--width", "--height", "--vertex", "--time", "--frames"].contains(key),
                  index + 1 < input.count, values[key] == nil else {
                throw GraphDiagnostic.invalid("usage: nm-render (--graph case.json | --dsl program.dsl) --out output.png --width 257 --height 129 [--vertex default-vertex.json] [--time 0.25 --frames 8]")
            }
            values[key] = input[index + 1]
            index += 2
        }
        guard (values["--graph"] == nil) != (values["--dsl"] == nil),
              let output = values["--out"],
              let widthString = values["--width"], let width = Int(widthString),
              let heightString = values["--height"], let height = Int(heightString) else {
            throw GraphDiagnostic.invalid("exactly one of --graph or --dsl, plus --out, --width and --height are required")
        }
        self.graph = values["--graph"].map(URL.init(fileURLWithPath:))
        self.dsl = values["--dsl"].map(URL.init(fileURLWithPath:))
        self.output = URL(fileURLWithPath: output)
        self.width = width
        self.height = height
        guard let time = Double(values["--time"] ?? "0"), time.isFinite,
              let frames = Int(values["--frames"] ?? "1"), (1...4096).contains(frames) else {
            throw GraphDiagnostic.invalid("--time must be finite and --frames must be 1...4096")
        }
        self.time = time
        self.frames = frames
        self.vertex = values["--vertex"].map(URL.init(fileURLWithPath:))
            ?? self.graph?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("default-vertex.json")
    }
}

func align(_ value: Int, to alignment: Int) -> Int {
    (value + alignment - 1) / alignment * alignment
}

func pngData(_ buffer: MTLBuffer, rowBytes: Int, size: RenderSize) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size.width,
        pixelsHigh: size.height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bitmapFormat: .alphaNonpremultiplied,
        bytesPerRow: size.width * 4, bitsPerPixel: 32),
        let pixels = bitmap.bitmapData else {
        throw GraphDiagnostic.missing("PNG bitmap")
    }
    let source = buffer.contents().assumingMemoryBound(to: UInt16.self)
    for y in 0..<size.height {
        // Upstream CanvasSink.present flips the backing render surface on
        // presentation. The core OutputLease retains unflipped graph pixels.
        let sourceY = size.height - 1 - y
        for x in 0..<size.width {
            for component in 0..<4 {
                let half = source[sourceY * rowBytes / 2 + x * 4 + component]
                let value = Float(Float16(bitPattern: half))
                guard value.isFinite else {
                    throw GraphDiagnostic.invalid("nonfinite render pixel at (\(x), \(y))")
                }
                let scaled = max(0, min(1, value)) * 255
                pixels[(y * size.width + x) * 4 + component] = UInt8(scaled.rounded())
            }
        }
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw GraphDiagnostic.missing("PNG encoder")
    }
    return data
}

func renderFrame(_ renderer: NoisemakerRenderer, queue: MTLCommandQueue,
                 frame: FrameState, capture: Bool,
                 externalTextures: [String: MTLTexture] = [:],
                 onEncoded: ((OutputLease) -> Void)? = nil) throws -> Data? {
    let size = renderer.size
    guard let command = queue.makeCommandBuffer() else {
        throw GraphDiagnostic.missing("Metal frame command buffer")
    }
    let lease = try renderer.encode(frame: frame, into: command,
        externalTextures: externalTextures)
    onEncoded?(lease)
    var readback: MTLBuffer?
    let rowBytes = align(size.width * 8, to: 256)
    if capture {
        guard let buffer = renderer.device.makeBuffer(length: rowBytes * size.height,
                options: .storageModeShared),
              let blit = command.makeBlitCommandEncoder() else {
            throw GraphDiagnostic.missing("Metal readback buffer or blit encoder")
        }
        blit.copy(from: lease.texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * size.height)
        blit.endEncoding()
        readback = buffer
    }
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else {
        throw command.error ?? GraphDiagnostic.invalid("Metal command buffer did not complete")
    }
    return try readback.map { try pngData($0, rowBytes: rowBytes, size: size) }
}

private func run() throws {
    let raw = Array(CommandLine.arguments.dropFirst())
    if raw.contains("--corpus") { try runCorpus(raw); return }
    let args = try Arguments(raw)
    let compiler: NoisemakerCompiler? = args.dsl == nil ? nil : try NoisemakerCompiler()
    let graph: RenderGraph
    if let path = args.graph {
        graph = try RenderGraph(exportedCaseData: Data(contentsOf: path))
    } else {
        graph = try compiler!.compile(source: String(contentsOf: args.dsl!, encoding: .utf8))
    }
    let size = try RenderSize(width: args.width, height: args.height)
    let vertexWGSL: String?, vertexEntry: String?
    if let path = args.vertex {
        let vertexJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        vertexWGSL = vertexJSON?["wgsl"] as? String
        vertexEntry = vertexJSON?["entryPoint"] as? String
    } else {
        vertexWGSL = compiler?.registry.defaultVertex.field("wgsl")?.stringValue
        vertexEntry = compiler?.registry.defaultVertex.field("entryPoint")?.stringValue
    }
    guard let vertexWGSL, let vertexEntry else {
        throw GraphDiagnostic.invalid("default vertex export lacks WGSL or entry point")
    }
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        throw GraphDiagnostic.missing("native Metal device or command queue")
    }
    let renderer = try NoisemakerRenderer(device: device, graph: graph, size: size,
        defaultVertexWGSL: vertexWGSL, vertexEntryPoint: vertexEntry,
        registry: compiler?.registry)
    var png: Data?
    for index in 0..<args.frames {
        let frame = FrameState(time: args.time, delta: 0, frameIndex: UInt64(index))
        png = try renderFrame(renderer, queue: queue, frame: frame,
            capture: index == args.frames - 1) ?? png
    }
    guard let png else { throw GraphDiagnostic.missing("final frame readback") }
    try png.write(to: args.output, options: .atomic)
    print("rendered \(graph.id) \(size.width)x\(size.height) frame \(args.frames) time \(args.time) to \(args.output.path)")
}

do {
    try run()
} catch {
    fputs("nm-render: \(error)\n", stderr)
    exit(1)
}
