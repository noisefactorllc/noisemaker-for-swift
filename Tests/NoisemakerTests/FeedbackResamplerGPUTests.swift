import Foundation
import Metal
import Testing
import CryptoKit
@testable import Noisemaker

@Suite(.serialized)
struct FeedbackResamplerGPUTests {
    @Test func rgba8FeedbackHalvesMatchSourcePixelsInBothResizeDirections() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice(), "Native Metal host required")
        let queue = try requireValue(device.makeCommandQueue())
        let scaler = try FeedbackResampler(device: device,
            formats: [.init(MTLPixelFormat.rgba8Unorm.rawValue)])
        let sourceHashes = [
            "5abdf7fa3e92f020fea98692f920b7f282f9ddde44a1fb24a80cb684d1e7026a",
            "44e5c43102d61ca93601deb7f5ecbf892ef6f990a0220a4839ac98400f403d9e",
            "68d723f856b6c8992009dae5ac01bb50a121e021136367394a16e4d8e51aeb9f",
            "a7905bd59e5aacc0935a3f765273dcd7e575edd06d7dfa1e2b80bd157f8db1f0",
            "2a52b37a11263d3f90bd5c59225e33a4562affcc2c5e8e710214a5e3e4411a8a",
            "cffd904e8c91d261ea703e201abf15dd805112b36884854915f1a9e99583d5a2",
            "4affc570b132f0e3709baa93621c9ccf63a8fcfe883322dcd217dd25803bfc53",
            "699be3f2b578cc93c82829d05423fb6053b3622b4fd20435e5cabdaa4bf64435",
            "c6dccaeebd3faaf44547282fb711c1a826dee4b751e2d887f16c03559cf3f184",
            "9d1b7f915a8f951124cdbdf1b84bca6acefdacd828e0e80978e2e1979ec4b2f9",
            "c459347a07bc9dc69dc911fa749815b9e870ce05d2b34bba7c2921cb198bc7ee",
            "db3265bad67131cf364fcd63e6467833980bf0eeed2f6d53605d852e9be62943"
        ]
        let targetHashes = [
            "9279c5239376c05740dd942e5489b2fcade4ceec57aa6ce553a57ce1496bd910",
            "78899f217b3df5a6221257faefe0552ee9f92c4e6ffaa0180fc46bc5c28c6a91",
            "862f5f6822d9f5683beaf2577ef70f4b3e5d8fd30445a3994a25f62e8678411d",
            "9fd35c7a63b5ef58aac996e9039e6550f0fddc1e207d64b60238b181e2661e69",
            "0737b96640593bd5450d8218b391bfda29507c2247eef6d59dac439830e0bb89",
            "adfb9fcd11c252c9d469b7b391d486d722c04ed6859caba3a55b9f0c1cb57c59",
            "9c501fd6cea5958b235479baede61c6eb16f79a29c5917ffa237bd9d20743a1c",
            "372af2d96285690908c839f3b07627b20cb26857e34d46c5ae43e566eecbc145",
            "9754aecc9fd947e1b1fe6c13d991f9df7ff1c632658c4146764762a2ea19e822",
            "9f301cfbcfc3d6899a5d0e8be2eab55be1cd7c694cacbbd2c23f0f9a5111fd07",
            "dcfc9ac83c9a9214250379a8358a7b17f865b6c1ec26cfe19cea5df077e6104f",
            "712770dbf9ff6bfd5dc7a9c6d4917ea381c8347725e9b57da2c836620962c586"
        ]
        func hash(_ bytes: [UInt8]) -> String {
            SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        }
        var caseIndex = 0
        for (width, height, outWidth, outHeight) in [
            (7, 5, 13, 9), (13, 9, 7, 5),
            (1, 7, 1, 13), (1, 13, 1, 7),
            (7, 1, 13, 1), (13, 1, 7, 1)
        ] {
            for variant in 0...1 {
                let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
                sourceDescriptor.storageMode = .shared
                sourceDescriptor.usage = .shaderRead
                let source = try requireValue(device.makeTexture(descriptor: sourceDescriptor))
                var input = [UInt8](repeating: 0, count: width * height * 4)
                for y in 0..<height { for x in 0..<width {
                    let i = (y * width + x) * 4
                    input[i] = UInt8((x * 41 + variant * 13) % 256)
                    input[i+1] = UInt8((y * 31 + variant * 17) % 256)
                    input[i+2] = UInt8((x * 17 + y * 29 + variant * 19) % 256)
                    input[i+3] = 255
                } }
                input.withUnsafeBytes { bytes in
                    source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: bytes.baseAddress!, bytesPerRow: width * 4)
                }
                let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba8Unorm, width: outWidth, height: outHeight, mipmapped: false)
                targetDescriptor.storageMode = .shared
                targetDescriptor.usage = [.shaderRead, .renderTarget]
                let target = try requireValue(device.makeTexture(descriptor: targetDescriptor))
                let command = try requireValue(queue.makeCommandBuffer())
                try scaler.encode(source: source, target: target, into: command)
                command.commit()
                command.waitUntilCompleted()
                expectEqual(command.status, .completed)
                if let error = command.error { throw error }
                var output = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
                target.getBytes(&output, bytesPerRow: outWidth * 4,
                    from: MTLRegionMake2D(0, 0, outWidth, outHeight), mipmapLevel: 0)
                expectEqual(hash(input), sourceHashes[caseIndex])
                expectEqual(hash(output), targetHashes[caseIndex])
                caseIndex += 1
            }
        }
    }
    @Test func oddDimensionsUseWebGL2CenterNearestMappingWithoutFlip() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let queue = try requireValue(device.makeCommandQueue())
        for (width, height, outWidth, outHeight) in [(7, 5, 13, 9), (13, 9, 7, 5)] {
            let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                width: width, height: height, mipmapped: false)
            sourceDescriptor.storageMode = .shared
            sourceDescriptor.usage = .shaderRead
            let source = try requireValue(device.makeTexture(descriptor: sourceDescriptor))
            var input = [Float](repeating: 0, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                input[i] = Float(x); input[i+1] = Float(y); input[i+2] = Float(x + y * width); input[i+3] = 1
            } }
            input.withUnsafeBytes { bytes in
                source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: bytes.baseAddress!, bytesPerRow: width * 16)
            }
            let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                width: outWidth, height: outHeight, mipmapped: false)
            targetDescriptor.storageMode = .shared
            targetDescriptor.usage = [.shaderRead, .renderTarget]
            let target = try requireValue(device.makeTexture(descriptor: targetDescriptor))
            let scaler = try FeedbackResampler(device: device, formats: [.init(MTLPixelFormat.rgba32Float.rawValue)])
            let command = try requireValue(queue.makeCommandBufferWithUnretainedReferences())
            try scaler.encode(source: source, target: target, into: command)
            command.commit(); command.waitUntilCompleted()
            expectEqual(command.status, .completed)
            if let error = command.error { throw error }
            var output = [Float](repeating: 0, count: outWidth * outHeight * 4)
            target.getBytes(&output, bytesPerRow: outWidth * 16,
                from: MTLRegionMake2D(0, 0, outWidth, outHeight), mipmapLevel: 0)
            for y in 0..<outHeight { for x in 0..<outWidth {
                let sx = min(Int((Float(x) + 0.5) * (Float(width) / Float(outWidth))), width - 1)
                let sy = min(Int((Float(y) + 0.5) * (Float(height) / Float(outHeight))), height - 1)
                let start = (y * outWidth + x) * 4, sourceStart = (sy * width + sx) * 4
                expectEqual(Array(output[start..<start+4]), Array(input[sourceStart..<sourceStart+4]))
            } }
        }
    }
    @Test func rgba32floatSourceAliasAllocatesBuddhabrotState() throws {
        let device = try requireValue(MTLCreateSystemDefaultDevice())
        let graph = try NoisemakerCompiler().compile(source:
            "search synth, points, render\nsolid().buddhabrot().pointsRender().write(o0)\nrender(o0)\n")
        let state = try FeedbackState(device: device, graph: graph, size: RenderSize(width: 33, height: 17))
        let floating = state.targets.filter { $0.key.contains("zState") }
        expectTrue(!floating.isEmpty)
        for texture in floating.values { expectEqual(texture.pixelFormat, .rgba32Float) }
    }
}
