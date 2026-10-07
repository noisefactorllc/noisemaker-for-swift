import Foundation
import Metal

struct ShaderResource {
    let name: String
    let kind: TintBindingKind
    let slot: Int
    let uniformPlan: UniformPlan?
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
    let workgroupSize: (UInt32, UInt32, UInt32)
    let storageSizeEntries: [TintBufferSize]
    let needsStorageSizes: Bool
}

enum ShaderCompiler {
    private static let bindingPattern = try! NSRegularExpression(pattern:
        #"@group\(\s*(\d+)\s*\)\s*@binding\(\s*(\d+)\s*\)\s*var(?:<([^>]+)>)?\s+(\w+)\s*:\s*([^;]+);"#)

    static func prepare(pass: GraphPass, program: GraphProgram, vertex: MTLFunction,
                        device: MTLDevice, translator: ShaderTranslator,
                        pixelFormats: [MTLPixelFormat]) throws -> PreparedRenderPass {
        let wgsl = program.resolvedWGSL
        let source = wgsl as NSString
        let matches = bindingPattern.matches(in: wgsl, range: NSRange(location: 0, length: source.length))
        guard matches.count == wgsl.components(separatedBy: "@group(").count - 1 else {
            throw GraphDiagnostic.unsupported("program \(program.id) has a resource declaration outside the supported WGSL subset")
        }
        var bindings: [TintBinding] = []
        var storageSizes: [TintBufferSize] = []
        var resources: [ShaderResource] = []
        var nextBuffer: UInt32 = 0, nextTexture: UInt32 = 0, nextSampler: UInt32 = 0
        for match in matches {
            func text(_ index: Int) -> String {
                match.range(at: index).location == NSNotFound ? "" : source.substring(with: match.range(at: index))
            }
            guard let group = UInt32(text(1)), let binding = UInt32(text(2)) else {
                throw GraphDiagnostic.invalid("program \(program.id) invalid resource location")
            }
            let addressSpace = text(3).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = text(4)
            let type = text(5).trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: TintBindingKind, slot: UInt32, uniformPlan: UniformPlan?
            if addressSpace == "uniform" {
                kind = .uniform; slot = nextBuffer; nextBuffer += 1
                uniformPlan = try UniformPlan.parse(type: type, wgsl: wgsl,
                    layout: program.raw.field("uniformLayout"), program: program.id)
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
            } else if type == "texture_2d<f32>" {
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
            resources.append(ShaderResource(name: name, kind: kind, slot: Int(slot), uniformPlan: uniformPlan))
        }
        let uniformNames = Set(resources.filter { $0.kind == .uniform }.flatMap { resource -> [String] in
            guard let plan = resource.uniformPlan else { return [] }
            if case .direct = plan { return [resource.name] }
            return Array(plan.requiredNames)
        })
        let passUniforms = Set(pass.uniforms.map(\.name))
        guard uniformNames.allSatisfy({ passUniforms.contains($0) || UniformPlan.isGlobal($0) }) else {
            throw GraphDiagnostic.unsupported("pass \(pass.id) uniforms differ from WGSL bindings")
        }
        let textureNames = Set(resources.filter { $0.kind == .texture }.map(\.name))
        guard textureNames.isSubset(of: Set(pass.inputs.map(\.key))) else {
            throw GraphDiagnostic.unsupported("pass \(pass.id) texture inputs differ from WGSL bindings")
        }
        if resources.contains(where: { $0.kind == .sampler }) && pass.inputs.count != 1 {
            throw GraphDiagnostic.unsupported("pass \(pass.id) sampler needs one texture input")
        }
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
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: translated.source, options: options)
        guard let function = library.makeFunction(name: translated.mslEntryPoint) else {
            throw GraphDiagnostic.missing("translated \(program.stage) \(translated.mslEntryPoint) in \(program.id)")
        }
        let pipeline: PreparedPipeline
        if program.stage == .compute {
            pipeline = .compute(try device.makeComputePipelineState(function: function))
        } else {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = pass.id
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = function
            for (index, format) in pixelFormats.enumerated() {
                descriptor.colorAttachments[index].pixelFormat = format
            }
            pipeline = .render(try device.makeRenderPipelineState(descriptor: descriptor))
        }
        return PreparedRenderPass(graphPass: pass, pipeline: pipeline,
            resources: resources, workgroupSize: translated.workgroupSize,
            storageSizeEntries: storageSizes, needsStorageSizes: translated.needsStorageBufferSizes)
    }
}
