import Foundation
import Metal

struct ShaderResource {
    let name: String
    let kind: TintBindingKind
    let slot: Int
    let uniformPlan: UniformPlan?
    let is3DTexture: Bool
}

struct WGSLBindingDeclaration {
    let group: UInt32
    let binding: UInt32
    let addressSpace: String
    let name: String
    let type: String
}

enum PreparedPipeline {
    case render(MTLRenderPipelineState)
    case compute(MTLComputePipelineState)

    var retainedObject: AnyObject {
        switch self {
        case .render(let pipeline): return pipeline
        case .compute(let pipeline): return pipeline
        }
    }
}

struct PreparedRenderPass {
    let graphPass: GraphPass
    let pipeline: PreparedPipeline
    let resources: [ShaderResource]
    let colorUniforms: Set<String>
    let customVertex: Bool
    let depthStencil: MTLDepthStencilState?
    let workgroupSize: (UInt32, UInt32, UInt32)
    let storageSizeEntries: [TintBufferSize]
    let needsStorageSizes: Bool
}

enum ShaderCompiler {
    private static let bindingPattern = try! NSRegularExpression(pattern:
        #"@group\s*\(\s*(\d+)\s*\)\s*@binding\s*\(\s*(\d+)\s*\)\s*var(?:<([^>]+)>)?\s+(\w+)\s*:\s*([^;]+);"#)
    private static let groupPattern = try! NSRegularExpression(pattern: #"@group\s*\("#)

    /// Mirrors WebGPUBackend.stripWGSLComments, including nested block
    /// comments. Replacing comment code units with spaces preserves binding
    /// locations and prevents commented-out uses from keeping dead resources.
    static func stripComments(_ source: String) -> String {
        let input = Array(source.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(input.count)
        var index = 0, blockDepth = 0
        while index < input.count {
            let current = input[index]
            let next = index + 1 < input.count ? input[index + 1] : 0
            if blockDepth > 0 {
                if current == 47 && next == 42 {
                    output.append(32); output.append(32); blockDepth += 1; index += 2
                } else if current == 42 && next == 47 {
                    output.append(32); output.append(32); blockDepth -= 1; index += 2
                } else {
                    output.append(current == 10 ? 10 : 32); index += 1
                }
            } else if current == 47 && next == 47 {
                output.append(32); output.append(32); index += 2
                while index < input.count && input[index] != 10 {
                    output.append(32); index += 1
                }
            } else if current == 47 && next == 42 {
                output.append(32); output.append(32); blockDepth = 1; index += 2
            } else {
                output.append(current); index += 1
            }
        }
        return String(decoding: output, as: UTF16.self)
    }

    /// A deliberately narrow proof that the default three-vertex full-screen
    /// draw replaces every pixel of its sole attachment. Unknown WGSL return
    /// forms stay on the retained-texture path. Tint validates the selected
    /// entry point before this graph can render.
    static func provesFullOverwrite(pass: GraphPass, program: GraphProgram) -> Bool {
        guard program.stage == .fragment, program.vertexEntryPoint == nil,
              pass.outputs.count == 1, pass.repeatCount == 1,
              pass.conditions == nil else { return false }
        for key in ["drawMode", "count", "countUniform", "viewport"] {
            if let value = pass.raw.field(key), !value.isUndefined { return false }
        }
        if let blend = pass.raw.field("blend"), !blend.isUndefined,
           blend.boolValue != false { return false }
        let clean = stripComments(program.resolvedWGSL)
        let tokens = wgslTokens(clean)
        guard !tokens.contains("discard"), !tokens.contains("sample_mask") else {
            return false
        }
        // Require one direct vec4 color return at location zero on the actual
        // selected entry. A struct, multiple outputs, or an unfamiliar WGSL
        // signature cannot accidentally enter the fast path.
        for index in tokens.indices where index + 4 < tokens.count &&
            Array(tokens[index...index + 3]) == ["@", "fragment", "fn", pass.entryPoint] &&
            tokens[index + 4] == "(" {
            var cursor = index + 5, depth = 1
            while cursor < tokens.count && depth > 0 {
                if tokens[cursor] == "(" { depth += 1 }
                if tokens[cursor] == ")" { depth -= 1 }
                cursor += 1
            }
            guard depth == 0, cursor + 10 < tokens.count else { return false }
            return Array(tokens[cursor...cursor + 9]) ==
                ["->", "@", "location", "(", "0", ")", "vec4", "<", "f32", ">"] &&
                tokens[cursor + 10] == "{"
        }
        return false
    }

    private static func wgslTokens(_ source: String) -> [String] {
        let scalars = Array(source.unicodeScalars)
        var tokens: [String] = []
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
                index += 1
                continue
            }
            if value == 95 || (65...90).contains(value) || (97...122).contains(value) {
                let start = index
                index += 1
                while index < scalars.count {
                    let next = scalars[index].value
                    guard next == 95 || (65...90).contains(next) ||
                          (97...122).contains(next) || (48...57).contains(next) else { break }
                    index += 1
                }
                tokens.append(String(String.UnicodeScalarView(scalars[start..<index])))
            } else if (48...57).contains(value) {
                let start = index
                index += 1
                while index < scalars.count && (48...57).contains(scalars[index].value) {
                    index += 1
                }
                tokens.append(String(String.UnicodeScalarView(scalars[start..<index])))
            } else if value == 45 && index + 1 < scalars.count && scalars[index + 1].value == 62 {
                tokens.append("->")
                index += 2
            } else {
                tokens.append(String(scalars[index]))
                index += 1
            }
        }
        return tokens
    }

    static func bindingDeclarations(_ wgsl: String) throws -> [WGSLBindingDeclaration] {
        let clean = stripComments(wgsl)
        let ns = clean as NSString
        let matches = bindingPattern.matches(in: clean,
            range: NSRange(location: 0, length: ns.length))
        guard matches.count == groupPattern.numberOfMatches(in: clean,
            range: NSRange(location: 0, length: ns.length)) else {
            throw GraphDiagnostic.unsupported("resource declaration outside the supported WGSL subset")
        }
        var declarations: [WGSLBindingDeclaration] = []
        for match in matches {
            func field(_ index: Int) -> String {
                match.range(at: index).location == NSNotFound ? "" : ns.substring(with: match.range(at: index))
            }
            guard let group = UInt32(field(1)), let binding = UInt32(field(2)) else {
                throw GraphDiagnostic.invalid("invalid WGSL resource location")
            }
            let address = field(3).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = field(4)
            let type = field(5).trimmingCharacters(in: .whitespacesAndNewlines)
            let storage = type.contains("texture_storage_2d") || address.contains("storage")
            if !storage {
                let escaped = NSRegularExpression.escapedPattern(for: name)
                let occurrences = try NSRegularExpression(pattern: #"\b"# + escaped + #"\b"#)
                    .numberOfMatches(in: clean, range: NSRange(location: 0, length: ns.length))
                if occurrences <= 1 { continue }
            }
            declarations.append(WGSLBindingDeclaration(group: group, binding: binding,
                addressSpace: address, name: name, type: type))
        }
        return declarations.sorted {
            $0.group == $1.group ? $0.binding < $1.binding : $0.group < $1.group
        }
    }

    static func prepare(pass: GraphPass, program: GraphProgram, vertex: MTLFunction,
                        device: MTLDevice, translator: ShaderTranslator,
                        pixelFormats: [MTLPixelFormat], colorUniforms: Set<String>) throws -> PreparedRenderPass {
        let wgsl = program.resolvedWGSL
        let declarations = try bindingDeclarations(wgsl)
        var bindings: [TintBinding] = []
        var storageSizes: [TintBufferSize] = []
        var resources: [ShaderResource] = []
        var nextBuffer: UInt32 = 0, nextTexture: UInt32 = 0, nextSampler: UInt32 = 0
        for declaration in declarations {
            let group = declaration.group, binding = declaration.binding
            let addressSpace = declaration.addressSpace
            let name = declaration.name
            let type = declaration.type
            let kind: TintBindingKind, slot: UInt32, uniformPlan: UniformPlan?
            if addressSpace == "uniform" {
                kind = .uniform; slot = nextBuffer; nextBuffer += 1
                // A program may combine a packed struct with direct uniforms
                // (remap uses separate tileOffset/fullResolution bindings).
                // The source backend applies its packed layout only to structs.
                let isStruct = !type.contains("<") &&
                    !["f32", "i32", "u32", "bool"].contains(type) &&
                    !type.hasPrefix("vec") && !type.hasPrefix("mat")
                uniformPlan = try UniformPlan.parse(type: type, wgsl: wgsl,
                    layout: isStruct ? program.raw.field("uniformLayout") : nil,
                    program: program.id)
            } else if addressSpace == "storage, read_write" &&
                      (name == "output_buffer" || name == "outputBuffer") &&
                      type.replacingOccurrences(of: " ", with: "") == "array<f32>" &&
                      program.stage == .compute {
                kind = .storage; slot = nextBuffer; nextBuffer += 1; uniformPlan = nil
                storageSizes.append(TintBufferSize(group: group, binding: binding,
                    index: UInt32(storageSizes.count)))
            } else if addressSpace.hasPrefix("storage") {
                throw GraphDiagnostic.unsupported("program \(program.id) storage buffer \(name) needs a declared compute resource plan")
            } else if type.hasPrefix("texture_storage_") {
                throw GraphDiagnostic.unsupported("program \(program.id) storage texture \(name) needs a declared output plan")
            } else if type == "texture_2d<f32>" || type == "texture_3d<f32>" {
                kind = .texture; slot = nextTexture; nextTexture += 1; uniformPlan = nil
            } else if type == "sampler" {
                kind = .sampler; slot = nextSampler; nextSampler += 1; uniformPlan = nil
            } else {
                throw GraphDiagnostic.unsupported("program \(program.id) resource \(name): \(addressSpace) \(type)")
            }
            guard nextBuffer <= 30 else {
                throw GraphDiagnostic.unsupported("program \(program.id) has too many Metal buffer bindings")
            }
            bindings.append(TintBinding(group: group, binding: binding, kind: kind, slot: slot))
            resources.append(ShaderResource(name: name, kind: kind, slot: Int(slot),
                uniformPlan: uniformPlan, is3DTexture: type == "texture_3d<f32>"))
        }
        // WebGPU creates zero/default uniform buffers for absent names and
        // binds a transparent dummy view for an unbound live texture. The
        // encoder's typed writer validates present values when a frame runs.
        if program.stage == .compute {
            guard pixelFormats.count == 1, storageSizes.count == 1,
                  resources.filter({ $0.kind == .storage }).count == 1 else {
                throw GraphDiagnostic.unsupported("pass \(pass.id) compute output requires one f32 storage buffer and one texture")
            }
        } else if !storageSizes.isEmpty {
            throw GraphDiagnostic.unsupported("pass \(pass.id) render storage output")
        }
        let translated = try translator.translate(wgsl: wgsl, entryPoint: pass.entryPoint,
            stage: program.stage, bindings: bindings, bufferSizes: storageSizes,
            bufferSizesOffset: storageSizes.isEmpty ? nil : 0, immediateSlot: 30)
        let function = try MetalVariantCache.shared.function(device: device,
            source: translated.source, name: translated.mslEntryPoint)
        let pipeline: PreparedPipeline
        var depthStencil: MTLDepthStencilState?
        if program.stage == .compute {
            pipeline = .compute(try MetalVariantCache.shared.computePipeline(
                device: device, function: function))
        } else {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = pass.id
            if let vertexEntry = program.vertexEntryPoint {
                let translatedVertex = try translator.translate(wgsl: wgsl,
                    entryPoint: vertexEntry, stage: .vertex, bindings: bindings)
                let customVertex = try MetalVariantCache.shared.function(device: device,
                    source: translatedVertex.source, name: translatedVertex.mslEntryPoint)
                descriptor.vertexFunction = customVertex
            } else {
                descriptor.vertexFunction = vertex
            }
            descriptor.fragmentFunction = function
            if pass.raw.field("drawMode")?.stringValue == "points" {
                descriptor.inputPrimitiveTopology = .point
            } else {
                descriptor.inputPrimitiveTopology = .triangle
            }
            if pass.raw.field("drawMode")?.stringValue == "triangles" {
                descriptor.depthAttachmentPixelFormat = .depth32Float
                let depth = MTLDepthStencilDescriptor()
                depth.depthCompareFunction = .less
                depth.isDepthWriteEnabled = true
                guard let state = device.makeDepthStencilState(descriptor: depth) else {
                    throw GraphDiagnostic.missing("Metal triangle depth state for \(pass.id)")
                }
                depthStencil = state
            }
            for (index, format) in pixelFormats.enumerated() {
                descriptor.colorAttachments[index].pixelFormat = format
                try configureBlend(descriptor.colorAttachments[index],
                    value: pass.raw.field("blend"), pass: pass.id)
            }
            let usesDepth = pass.raw.field("drawMode")?.stringValue == "triangles"
            pipeline = .render(try MetalVariantCache.shared.renderPipeline(device: device,
                descriptor: descriptor, depthCompare: usesDepth ? .less : nil,
                depthWrite: usesDepth))
        }
        return PreparedRenderPass(graphPass: pass, pipeline: pipeline,
            resources: resources, colorUniforms: colorUniforms,
            customVertex: program.vertexEntryPoint != nil, depthStencil: depthStencil,
            workgroupSize: translated.workgroupSize,
            storageSizeEntries: storageSizes, needsStorageSizes: translated.needsStorageBufferSizes)
    }

    private static func configureBlend(_ attachment: MTLRenderPipelineColorAttachmentDescriptor,
                                       value: GraphValue?, pass: String) throws {
        guard let value, !value.isUndefined else { return }
        let source: MTLBlendFactor, destination: MTLBlendFactor
        switch value {
        case .bool(false): return
        case .bool(true):
            source = .one
            destination = .one
        case .array(let factors) where factors.count == 2:
            guard let first = factors[0].stringValue,
                  let second = factors[1].stringValue else {
                throw GraphDiagnostic.unsupported("pass \(pass) blend factors must be strings")
            }
            source = try blendFactor(first, pass: pass)
            destination = try blendFactor(second, pass: pass)
        default:
            throw GraphDiagnostic.unsupported("pass \(pass) blend mode")
        }
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = source
        attachment.sourceAlphaBlendFactor = source
        attachment.destinationRGBBlendFactor = destination
        attachment.destinationAlphaBlendFactor = destination
    }

    private static func blendFactor(_ value: String, pass: String) throws -> MTLBlendFactor {
        switch value.uppercased() {
        case "ZERO": return .zero
        case "ONE": return .one
        case "SRC_COLOR": return .sourceColor
        case "ONE_MINUS_SRC_COLOR": return .oneMinusSourceColor
        case "DST_COLOR": return .destinationColor
        case "ONE_MINUS_DST_COLOR": return .oneMinusDestinationColor
        case "SRC_ALPHA": return .sourceAlpha
        case "ONE_MINUS_SRC_ALPHA": return .oneMinusSourceAlpha
        case "DST_ALPHA": return .destinationAlpha
        case "ONE_MINUS_DST_ALPHA": return .oneMinusDestinationAlpha
        case "CONSTANT_COLOR": return .blendColor
        case "ONE_MINUS_CONSTANT_COLOR": return .oneMinusBlendColor
        case "CONSTANT_ALPHA": return .blendAlpha
        case "ONE_MINUS_CONSTANT_ALPHA": return .oneMinusBlendAlpha
        case "SRC_ALPHA_SATURATE": return .sourceAlphaSaturated
        default: throw GraphDiagnostic.unsupported("pass \(pass) blend factor \(value)")
        }
    }
}
