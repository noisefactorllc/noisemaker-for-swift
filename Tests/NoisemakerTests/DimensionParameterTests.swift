import Foundation
import Testing
@testable import Noisemaker

@Suite(.serialized)
struct DimensionParameterTests {
    @Test func sourceCapabilityProfileClampsUniformsAndAtlasTogether() throws {
        let compiler = try NoisemakerCompiler()
        let source = "search synth3d, render\nnoise3d(volumeSize: x128).render3d().write(o0)\nrender(o0)\n"
        let original = try compiler.compile(source: source)
        // Locked Pipeline on the same M2: WebGPU advertises 8192 and clamps to
        // 64, while WebGL2 advertises 16384 and retains 128.
        for (limit, expected) in [(4096, 64.0), (8192, 64.0), (16384, 128.0)] {
            let graph = try original.clampingVolumeSizes(maximumTextureDimension2D: limit,
                                                        registry: compiler.registry)
            expectEqual(graph.source, original.source)
            for pass in graph.passes {
                for field in pass.uniforms where field.name == "volumeSize" ||
                    field.name.hasPrefix("volumeSize_chain_") {
                    expectEqual(field.value.numberValue, expected)
                }
            }
            let atlas = try requireValue(graph.textures.first { $0.key.hasSuffix("volumeCache") })
            expectEqual(try atlas.width.resolve(screen: 256, parameters: graph.dimensionParameters), Int(expected))
            expectEqual(try atlas.height.resolve(screen: 256, parameters: graph.dimensionParameters), Int(expected * expected))
        }
        expectEqual(original.dimensionParameters["volumeSize_chain_0"], 128)
    }

    @Test func fractionalSourceDimensionsClampToOnePixel() throws {
        // Pipeline.resolveDimension applies max(1, floor(...)) after percentages
        // and parameter transforms, including normalize's 0.1% reduction target.
        expectEqual(try GraphDimension.percent(0.1).resolve(screen: 256, parameters: [:]), 1)
        expectEqual(try GraphDimension.parameter(name: "size", fallback: 64, power: 1,
            multiply: 1).resolve(screen: 256, parameters: ["size": 0.25]), 1)
    }

    @Test func sourceLastPassSizingValueWins() throws {
        let sources = [
            "search synth, points, render\nsolid().pointsEmit(stateSize: 128).life().pointsRender().write(o0)\nrender(o0)\n",
            "search synth, points, render\nsolid().pointsEmit(stateSize: 512).attractor().pointsBillboardRender(viewMode: perspective).write(o0)\nrender(o0)\n"
        ]
        let compiler = try NoisemakerCompiler()
        for source in sources {
            let graph = try compiler.compile(source: source)
            let values = graph.passes.compactMap {
                $0.uniforms.first(where: { $0.name == "stateSize_node_1" })?.value.numberValue
            }
            expectTrue(Set(values).count > 1)
            expectEqual(graph.dimensionParameters["stateSize_node_1"], 256)
            for texture in graph.textures {
                if case .parameter(let name, _, _, _) = texture.width, name == "stateSize_node_1" {
                    expectEqual(try texture.width.resolve(screen: 256, parameters: graph.dimensionParameters),
                                Int(try requireValue(values.last)))
                }
            }
        }
    }
}
