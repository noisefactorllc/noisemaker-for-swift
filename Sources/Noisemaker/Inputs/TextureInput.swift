import Foundation
import Metal

/// Binary, straight-alpha image upload. Prepare a new texture before publishing
/// it to a frame; do not mutate one still held by an in-flight command buffer.
public enum TextureInput {
    /// Tightly packed x-fastest RGBA8 volume. The caller retains and supplies
    /// the returned texture for each frame that samples this host input.
    public static func rgba8Volume(device: MTLDevice, pixels: Data,
                                   width: Int, height: Int, depth: Int) throws -> MTLTexture {
        guard width > 0, height > 0, depth > 0,
              width <= 2_048, height <= 2_048, depth <= 2_048,
              width <= Int.max / 4 / height,
              width * height <= Int.max / 4 / depth,
              pixels.count == width * height * depth * 4 else {
            throw GraphDiagnostic.invalid("RGBA8 volume byte count or dimensions are invalid")
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.depth = depth
        descriptor.mipmapLevelCount = 1
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GraphDiagnostic.missing("RGBA8 host volume")
        }
        pixels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, width, height, depth),
                mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!,
                bytesPerRow: width * 4, bytesPerImage: width * height * 4)
        }
        return texture
    }

    public static func rgba8(device: MTLDevice, pixels: Data, size: RenderSize,
                             flipY: Bool = false) throws -> MTLTexture {
        let rowBytes = size.width * 4
        guard pixels.count == rowBytes * size.height else {
            throw GraphDiagnostic.invalid("RGBA8 input byte count does not match its dimensions")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,
            width:size.width,height:size.height,mipmapped:false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor:descriptor) else {
            throw GraphDiagnostic.missing("RGBA8 host texture")
        }
        pixels.withUnsafeBytes { raw in
            if flipY {
                for row in 0..<size.height {
                    texture.replace(region:MTLRegionMake2D(0,row,size.width,1),mipmapLevel:0,
                        withBytes:raw.baseAddress!.advanced(by:(size.height-1-row)*rowBytes),bytesPerRow:rowBytes)
                }
            } else {
                texture.replace(region:MTLRegionMake2D(0,0,size.width,size.height),mipmapLevel:0,
                                withBytes:raw.baseAddress!,bytesPerRow:rowBytes)
            }
        }
        return texture
    }
}
