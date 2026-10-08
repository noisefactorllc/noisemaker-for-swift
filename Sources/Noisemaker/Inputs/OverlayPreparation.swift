import Foundation

extension BuiltinOverlay {
    /// Prepares every source CPU overlay once for this graph and render size.
    /// Hosts publish the resulting binary textures together at a frame boundary.
    public static func prepare(graph: RenderGraph, size: RenderSize) throws -> [String:OverlayPixels] {
        var result: [String:OverlayPixels] = [:]
        var specifications: [String:String] = [:]
        for pass in graph.passes {
            guard let effect = pass.raw.field("effectKey")?.stringValue,
                  effect.hasPrefix("filter."),
                  let kind = BuiltinOverlayKind(rawValue:String(effect.dropFirst(7))) else { continue }
            let inputs = pass.inputs.filter {$0.key == "overlayTex"}
            guard inputs.count == 1, let id = inputs[0].value.stringValue,
                  graph.externalTextureNames.contains(id),
                  let texture = graph.textures.first(where:{$0.key == id}),
                  texture.format == "rgba8",
                  try texture.width.resolve(screen:size.width,parameters:graph.dimensionParameters) == size.width,
                  try texture.height.resolve(screen:size.height,parameters:graph.dimensionParameters) == size.height else {
                throw GraphDiagnostic.invalid("\(effect) needs one screen-sized rgba8 overlayTex input")
            }
            func parameter(_ name:String) throws -> Double {
                guard let number = pass.uniforms.first(where:{$0.name == name})?.value.numberValue,
                      number.isFinite else { throw GraphDiagnostic.invalid("\(effect) requires numeric \(name) for CPU preparation") }
                return number
            }
            if case .bool(true) = texture.raw.field("is3D") {
                throw GraphDiagnostic.invalid("CPU overlay texture must be 2D")
            }
            let seed = try parameter("seed"), density = try parameter("density")
            let signature = "\(kind.rawValue):\(seed):\(density)"
            if let existing = specifications[id] {
                guard existing == signature else { throw GraphDiagnostic.invalid("conflicting CPU overlays for \(id)") }
                continue
            }
            specifications[id] = signature
            let canvas = try render(kind,size:size,seed:seed,density:density)
            // Source asyncInit paints a top-down Canvas, then uploads it with
            // flipY: true. Publish the uploaded texture's row order while
            // keeping BuiltinOverlay.render's raw Canvas contract intact.
            let rowBytes = size.width * 4
            var uploaded = Data(count: canvas.rgba.count)
            uploaded.withUnsafeMutableBytes { destination in
                canvas.rgba.withUnsafeBytes { source in
                    for row in 0..<size.height {
                        destination.baseAddress!.advanced(by: row * rowBytes).copyMemory(
                            from: source.baseAddress!.advanced(by: (size.height - 1 - row) * rowBytes),
                            byteCount: rowBytes)
                    }
                }
            }
            result[id] = OverlayPixels(size:size,rgba:uploaded)
        }
        return result
    }
}
