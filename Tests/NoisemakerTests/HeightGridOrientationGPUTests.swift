import Foundation
import Metal
import Testing
@testable import Noisemaker
@testable import NoisemakerMetalKit

@Suite(.serialized)
struct HeightGridOrientationGPUTests {
    private struct PresentedImage {
        let width: Int
        let height: Int
        let bgra: [UInt8]

        func color(_ x: Int, _ y: Int) -> (red: Int, green: Int, blue: Int) {
            let index = (y * width + x) * 4
            return (Int(bgra[index + 2]), Int(bgra[index + 1]), Int(bgra[index]))
        }

        func averageLitColor(near center: (Int, Int)) throws -> (red: Double, green: Double) {
            var red = 0
            var green = 0
            var count = 0
            for y in (center.1 - 3)...(center.1 + 3) {
                for x in (center.0 - 3)...(center.0 + 3) {
                    let pixel = color(x, y)
                    if pixel.red + pixel.green + pixel.blue == 0 { continue }
                    red += pixel.red
                    green += pixel.green
                    count += 1
                }
            }
            try #require(count > 0, "No lit pixels near \(center)")
            return (Double(red) / Double(count), Double(green) / Double(count))
        }

        func litPositions() -> [(Int, Int)] {
            var positions: [(Int, Int)] = []
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = color(x, y)
                    if pixel.red + pixel.green + pixel.blue > 0 { positions.append((x, y)) }
                }
            }
            return positions
        }
    }

    private func capture(_ source: String, width: Int, height: Int,
                         frames: Int = 1) throws -> PresentedImage {
        let device = try #require(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try #require(device.makeCommandQueue())
        let registry = try EffectRegistry.bundled()
        let graph = try NoisemakerCompiler(registry: registry).compile(source: source)
        let vertex = registry.defaultVertex
        let renderer = try NoisemakerRenderer(device: device, graph: graph,
            size: RenderSize(width: width, height: height),
            defaultVertexWGSL: try #require(vertex.field("wgsl")?.stringValue),
            vertexEntryPoint: try #require(vertex.field("entryPoint")?.stringValue),
            registry: registry)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        let presented = try #require(device.makeTexture(descriptor: descriptor))
        let presenter = try TexturePresenter(device: device)
        for frame in 0..<frames {
            let command = try #require(queue.makeCommandBuffer())
            let output = try renderer.encode(frame: FrameState(time: 0, delta: 0,
                frameIndex: UInt64(frame)), into: command)
            if frame == frames - 1 {
                // Raw graph textures are vertically inverted relative to the canvas.
                // The production presenter restores the screen orientation on GPU.
                try presenter.encode(source: output.texture, target: presented, into: command)
            }
            command.commit()
            command.waitUntilCompleted()
            try #require(command.status == .completed,
                "Metal frame \(frame) failed: \(String(describing: command.error))")
            if let error = command.error { throw error }
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        presented.getBytes(&pixels, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return PresentedImage(width: width, height: height, bgra: pixels)
    }

    @Test func topDownDiffuseImageHasAuthoredOrientationInBothRenderers() throws {
        let size = 128
        let image = try capture("search synth\ntestPattern(pattern: uvMap).write(o0)\nrender(o0)",
            width: size, height: size)
        let corners = [(44, 44), (84, 44), (44, 84)]
        let reference = try corners.map { try image.averageLitColor(near: $0) }
        let referenceAcross = reference[1].red - reference[0].red
        let referenceDown = reference[2].green - reference[0].green
        #expect(abs(referenceAcross) > 48)
        #expect(abs(referenceDown) > 48)

        for renderer in [
            "pointsRender(viewMode: perspective, rotateX: 1.5708, density: 100, intensity: 0, inputIntensity: 0)",
            "pointsBillboardRender(viewMode: perspective, rotateX: 1.5708, density: 100, intensity: 0, inputIntensity: 0, shapeMode: square, pointSize: 3, depositOpacity: 20, blendMode: alpha)"
        ] {
            let source = """
                search synth, points, render
                testPattern(pattern: uvMap).write(o1)
                solid(color: #ffffff).pointsEmit(stateSize: x128).heightGrid(heightScale: 0, diffuseTex: read(o1)).\(renderer).write(o0)
                render(o0)
                """
            let view = try capture(source, width: size, height: size, frames: 4)
            let sampled = try corners.map { try view.averageLitColor(near: $0) }
            let across = sampled[1].red - sampled[0].red
            let down = sampled[2].green - sampled[0].green
            #expect(across * referenceAcross > 0, "\(renderer): horizontal gradient mirrored")
            #expect(abs(across) > 32, "\(renderer): horizontal gradient missing")
            #expect(down * referenceDown > 0, "\(renderer): vertical gradient mirrored")
            #expect(abs(down) > 32, "\(renderer): vertical gradient missing")
        }
    }

    @Test func billboardPerspectiveProjectsCorrectedGridRowAndFocusDepth() throws {
        let width = 160
        let height = 144
        func source(_ camera: String, _ focus: String = "aperture: 0") -> String {
            """
            search synth, points, render
            solid(color: #ffffff).pointsEmit(stateSize: x64, layout: center, resetState: true)
              .heightGrid(gridScale: 64, heightScale: 0, heightOffset: 12)
              .pointsBillboardRender(viewMode: perspective, density: 0.001, intensity: 0, inputIntensity: 0, shapeMode: square, pointSize: 8, depositOpacity: 100, rotateX: 0, rotateY: 0, rotateZ: 0, viewScale: 1, posX: 0, posY: 0, \(camera), \(focus)).write(o0)
            render(o0)
            """
        }
        // Slot zero is (-31.5, 12, +31.5), so the camera at Z=80 sees
        // depth 48.5. These expected screen pixels are hand-derived from the
        // perspective transform for the 160 by 144 viewport.
        for (label, camera, expected) in [
            ("default", "posZ: 0, fieldOfView: 90", (33, 54)),
            ("wide", "posZ: 0, fieldOfView: 115", (50, 60)),
            ("forward", "posZ: 15, fieldOfView: 90", (12, 46))
        ] {
            let image = try capture(source(camera), width: width, height: height)
            let pixels = image.litPositions()
            try #require(!pixels.isEmpty, "\(label): no billboard pixels")
            let centerX = Double(pixels.reduce(0) { $0 + $1.0 }) / Double(pixels.count)
            let centerY = Double(pixels.reduce(0) { $0 + $1.1 }) / Double(pixels.count)
            #expect(abs(centerX - Double(expected.0)) <= 1.5,
                "\(label): projected X \(centerX), expected \(expected.0)")
            #expect(abs(centerY - Double(expected.1)) <= 1.5,
                "\(label): projected Y \(centerY), expected \(expected.1)")
        }
        let focused = try capture(source("posZ: 0, fieldOfView: 90", "aperture: 12, focalDistance: 48.5"),
            width: width, height: height)
        let defocused = try capture(source("posZ: 0, fieldOfView: 90", "aperture: 12, focalDistance: 111.5"),
            width: width, height: height)
        let focusedPixels = focused.litPositions()
        let defocusedPixels = defocused.litPositions()
        try #require(!focusedPixels.isEmpty && !defocusedPixels.isEmpty)
        #expect(defocusedPixels.count > focusedPixels.count,
            "Corrected +Z grid row must be sharp at camera depth 48.5 and blur at 111.5")
    }
}
