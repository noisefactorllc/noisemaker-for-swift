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
            multiply: 1, nonfiniteFallback: 64).resolve(screen: 256, parameters: ["size": 0.25]), 1)
    }

    @Test func percentagesAboveOneHundredResolveBeforeCapabilityValidation() throws {
        for (text, expected) in [("200%", 128), ("150.5%", 96), ("0.1%", 1)] {
            let dimension = try GraphDimension.decode(.string(text), context: "percentage")
            expectEqual(try dimension.resolve(screen: 64, parameters: [:]), expected)
        }
        let oversized = try GraphDimension.decode(.string("100000%"), context: "percentage")
        expectThrows(try oversized.resolve(screen: 64, parameters: [:]))
        for text in ["0%", "-1%", "inf%", "nan%"] {
            expectThrows(try GraphDimension.decode(.string(text), context: "percentage"))
        }
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
                if case .parameter(let name, _, _, _, _) = texture.width, name == "stateSize_node_1" {
                    expectEqual(try texture.width.resolve(screen: 256, parameters: graph.dimensionParameters),
                                Int(try requireValue(values.last)))
                }
            }
        }
    }

    @Test func nonfiniteParametersTakeTheSpecDefaultAsResolveDimensionDoes() throws {
        // Pipeline.resolveDimension: a nonnumeric value takes the spec's own
        // default, else paramDefault (64 when absent) with multiply and power.
        func dimension(_ json: String) throws -> GraphDimension {
            try GraphDimension.decode(OrderedJSON.decode(Data(json.utf8)), context: "test")
        }
        let withDefault = try dimension(#"{"param":"stateSize","inherit":true,"default":256}"#)
        let withoutDefault = try dimension(#"{"param":"stateSize","inherit":true}"#)
        let transformed = try dimension(#"{"param":"volumeSize","paramDefault":16,"power":2}"#)
        for value in [Double.nan, .infinity] {
            expectEqual(try withDefault.resolve(screen: 512, parameters: ["stateSize": value]), 256)
            expectEqual(try withoutDefault.resolve(screen: 512, parameters: ["stateSize": value]), 64)
            expectEqual(try transformed.resolve(screen: 512, parameters: ["volumeSize": value]), 256)
        }
        expectEqual(try withDefault.resolve(screen: 512, parameters: ["stateSize": 128]), 128)
        // A missing parameter without a transform takes paramDefault, not default.
        expectEqual(try withDefault.resolve(screen: 512, parameters: [:]), 64)
    }

    @Test func functionValuedStateSizeSizesParticleMemoryFromTextureDefaults() throws {
        // qtPrograms/funcNodeScoped. The source pipeline sizes its textures from
        // the compiled graph, where stateSize is a function: pointsEmit's state
        // and physarum's base color both take their spec default, 256.
        let source = "search points, synth, render\n\nsolid().pointsEmit(stateSize: () => 128).physarum().pointsRender().write(o0)\n\nrender(o0)\n"
        let compiler = try NoisemakerCompiler()
        for graph in [try compiler.compile(source: source), try compiler.compileForHost(source: source)] {
            for name in ["global_xyz_node_1", "global_vel_node_1", "global_rgba_node_1",
                         "global_physarum_base_color_node_1"] {
                let texture = try requireValue(graph.textures.first { $0.key == name })
                expectEqual(try texture.width.resolve(screen: 256, parameters: graph.dimensionParameters), 256, name)
                expectEqual(try texture.height.resolve(screen: 256, parameters: graph.dimensionParameters), 256, name)
            }
        }
    }
}
