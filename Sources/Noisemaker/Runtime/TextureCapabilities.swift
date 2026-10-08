import Foundation
import Metal

/// The renderer currently supports dimensions through 16384. Query the device's
/// family before selecting that limit; callers may request a smaller profile.
/// https://developer.apple.com/metal/capabilities/
enum TextureCapabilities {
    static func maximum2DDimension(for device: MTLDevice) throws -> Int {
        if device.supportsFamily(.apple3) || device.supportsFamily(.mac2) { return 16_384 }
        if device.supportsFamily(.apple2) { return 8_192 }
        throw GraphDiagnostic.unsupported("Metal GPU family has no qualified texture limit")
    }
}

extension RenderGraph {
    /// Pipeline.clampGraphVolumeSizes prepares numeric atlas dimensions before
    /// allocation. Compiler stages and authored DSL remain device-independent.
    func clampingVolumeSizes(maximumTextureDimension2D limit: Int,
                             registry: EffectRegistry) throws -> RenderGraph {
        guard limit > 0 else { throw GraphDiagnostic.invalid("texture dimension limit must be positive") }
        guard var passValues = raw.field("passes")?.arrayValue else {
            throw GraphDiagnostic.invalid("graph has no passes")
        }
        var changed = false
        for index in passValues.indices {
            var pass = OrderedObject(passValues[index])
            var uniforms = OrderedObject(pass["uniforms"])
            for field in uniforms.fields {
                guard field.name == "volumeSize" || field.name.hasPrefix("volumeSize_chain_") ||
                        field.name.hasPrefix("volumeSize_node_"),
                      let value = field.value.numberValue, value * value > Double(limit) else { continue }
                var clamped = 16.0
                while (clamped * 2) * (clamped * 2) <= Double(limit) && clamped * 2 < value {
                    clamped *= 2
                }
                if value != clamped {
                    uniforms[field.name] = .number(clamped)
                    changed = true
                }
            }
            pass["uniforms"] = uniforms.value
            passValues[index] = pass.value
        }
        guard changed else { return self }
        var graph = OrderedObject(raw)
        graph["passes"] = .array(passValues)
        let bytes = try NoisemakerCompiler(registry: registry).makeRenderGraphInput(graph.value)
        return try RenderGraph(exportedCaseData: bytes)
    }
}
