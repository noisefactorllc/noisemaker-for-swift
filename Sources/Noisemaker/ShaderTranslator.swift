import Foundation
import CNoisemakerTint

public enum TintStage: UInt32, Sendable {
    case vertex, fragment, compute
}

public enum TintBindingKind: UInt32, Sendable {
    case uniform = 0
    case storage = 1
    case texture = 2
    case storageTexture = 3
    case sampler = 4
}

public struct TintBinding: Hashable, Sendable {
    public let group: UInt32
    public let binding: UInt32
    public let kind: TintBindingKind
    public let slot: UInt32

    public init(group: UInt32, binding: UInt32, kind: TintBindingKind, slot: UInt32) {
        self.group = group
        self.binding = binding
        self.kind = kind
        self.slot = slot
    }
}

public struct TintBufferSize: Hashable, Sendable {
    public let group: UInt32
    public let binding: UInt32
    public let index: UInt32

    public init(group: UInt32, binding: UInt32, index: UInt32) {
        self.group = group
        self.binding = binding
        self.index = index
    }
}

public struct TintTranslation: Sendable {
    public let source: String
    public let entryPoint: String
    public let mslEntryPoint: String
    public let stage: TintStage
    public let workgroupSize: (UInt32, UInt32, UInt32)
    public let needsStorageBufferSizes: Bool
    public let hasInvariantAttribute: Bool
    public let bufferSizes: [TintBufferSize]
    public let bufferSizesOffset: UInt32?
    public let immediateSlot: UInt32?
    public let dawnRevision: String
    public let strictMath: Bool
}

public enum TintTranslationError: Error, Equatable {
    case invalidInput(String)
    case translationFailed(String)
}

public struct ShaderTranslator: Sendable {
    private static let compilationLock = NSLock()
    private static let remappedEntryPoint = "dawn_entry_point"

    public init() {}

    public func translate(
        wgsl: String,
        entryPoint: String,
        stage: TintStage,
        bindings: [TintBinding] = [],
        bufferSizes: [TintBufferSize] = [],
        bufferSizesOffset: UInt32? = nil,
        immediateSlot: UInt32? = 30,
        appleGPUFamily9: Bool = false,
        strictMath: Bool = true
    ) throws -> TintTranslation {
        guard !entryPoint.isEmpty, !entryPoint.utf8.contains(0) else {
            throw TintTranslationError.invalidInput("entry point must be a nonempty C string")
        }
        guard bufferSizes.isEmpty == (bufferSizesOffset == nil) else {
            throw TintTranslationError.invalidInput("storage sizes and their offset must be provided together")
        }
        if !bufferSizes.isEmpty && immediateSlot == nil {
            throw TintTranslationError.invalidInput("storage sizes require an immediate buffer slot")
        }
        if let immediateSlot, immediateSlot > 30 {
            throw TintTranslationError.invalidInput("immediate buffer slot exceeds Metal slot 30")
        }
        if let bufferSizesOffset, bufferSizesOffset % 4 != 0 {
            throw TintTranslationError.invalidInput("storage-size offset must be 4-byte aligned")
        }
        var seenSizes = Set<String>()
        var seenIndices = Set<UInt32>()
        for size in bufferSizes {
            guard seenSizes.insert("\(size.group):\(size.binding)").inserted,
                  seenIndices.insert(size.index).inserted else {
                throw TintTranslationError.invalidInput("duplicate storage-size binding or index")
            }
            if let bufferSizesOffset,
               UInt64(bufferSizesOffset) + (UInt64(size.index) + 1) * 4 > 64 {
                throw TintTranslationError.invalidInput("storage-size entry exceeds Tint immediate block")
            }
        }
        var seenWGSL = Set<String>()
        var seenMetal = Set<String>()
        for binding in bindings {
            let sourceKey = "\(binding.group):\(binding.binding)"
            guard seenWGSL.insert(sourceKey).inserted else {
                throw TintTranslationError.invalidInput("duplicate WGSL binding \(sourceKey)")
            }
            let space = binding.kind == .sampler ? "sampler" :
                (binding.kind == .texture || binding.kind == .storageTexture ? "texture" : "buffer")
            guard seenMetal.insert("\(space):\(binding.slot)").inserted else {
                throw TintTranslationError.invalidInput("duplicate Metal \(space) slot \(binding.slot)")
            }
            if space == "buffer" && binding.slot == immediateSlot {
                throw TintTranslationError.invalidInput("resource collides with immediate buffer slot")
            }
        }
        for size in bufferSizes {
            guard bindings.contains(where: {
                $0.group == size.group && $0.binding == size.binding && $0.kind == .storage
            }) else {
                throw TintTranslationError.invalidInput("storage-size entry has no storage binding")
            }
        }

        let rawBindings = bindings.map { binding -> nm_tint_binding in
            var raw = nm_tint_binding()
            raw.group = binding.group
            raw.binding = binding.binding
            raw.kind = binding.kind.rawValue
            raw.slot = binding.slot
            return raw
        }
        let rawSizes = bufferSizes.map { size -> nm_tint_buffer_size in
            var raw = nm_tint_buffer_size()
            raw.group = size.group
            raw.binding = size.binding
            raw.index = size.index
            return raw
        }
        var options = nm_tint_options()
        options.stage = stage.rawValue
        options.strip_all_names = 1
        options.fixed_sample_mask = UInt32.max
        options.has_immediate_binding = immediateSlot == nil ? 0 : 1
        options.immediate_slot = immediateSlot ?? 0
        options.has_buffer_sizes_offset = bufferSizesOffset == nil ? 0 : 1
        options.buffer_sizes_offset = bufferSizesOffset ?? 0
        options.has_vertex_pulling = stage == .vertex ? 1 : 0
        options.vertex_pulling_group = 4
        options.fix_u32_div_mod = 1
        options.polyfill_unpack_2x16_snorm = appleGPUFamily9 ? 1 : 0
        options.polyfill_unpack_2x16_unorm = appleGPUFamily9 ? 1 : 0
        options.disable_demote_to_helper = 1
        options.allow_unsafe_apis = 1
        options.dawn_heading = 1
        options.strict_math = strictMath ? 1 : 0

        // Tint is currently serialized. Input pointers remain alive until the synchronous C call returns.
        Self.compilationLock.lock()
        defer { Self.compilationLock.unlock() }
        let bytes = Array(wgsl.utf8)
        let result: (Int32, nm_tint_output) = bytes.withUnsafeBufferPointer { source in
            entryPoint.withCString { entryName in
                Self.remappedEntryPoint.withCString { remapped in
                    rawBindings.withUnsafeBufferPointer { bindingTable in
                        rawSizes.withUnsafeBufferPointer { sizeTable in
                            options.entry_point = entryName
                            options.remapped_entry_point = remapped
                            options.bindings = bindingTable.baseAddress
                            options.binding_count = bindingTable.count
                            options.buffer_sizes = sizeTable.baseAddress
                            options.buffer_size_count = sizeTable.count
                            var output = nm_tint_output()
                            let status = nm_tint_wgsl_to_msl(
                                source.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                source.count, &options, &output)
                            return (status, output)
                        }
                    }
                }
            }
        }
        var output = result.1
        defer { nm_tint_output_free(&output) }
        guard result.0 == 1, let msl = output.msl else {
            let message = output.error.map { String(cString: $0) } ?? "Tint returned no MSL or diagnostic"
            throw TintTranslationError.translationFailed(message)
        }
        let mslBytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(msl).assumingMemoryBound(to: UInt8.self),
            count: output.msl_len)
        guard let source = String(bytes: mslBytes, encoding: .utf8) else {
            throw TintTranslationError.translationFailed("Tint returned non-UTF-8 MSL")
        }
        return TintTranslation(
            source: source,
            entryPoint: entryPoint,
            mslEntryPoint: Self.remappedEntryPoint,
            stage: stage,
            workgroupSize: (output.workgroup_size.0, output.workgroup_size.1, output.workgroup_size.2),
            needsStorageBufferSizes: output.needs_storage_buffer_sizes != 0,
            hasInvariantAttribute: output.has_invariant_attribute != 0,
            bufferSizes: bufferSizes,
            bufferSizesOffset: bufferSizesOffset,
            immediateSlot: immediateSlot,
            dawnRevision: String(cString: nm_tint_dawn_revision()),
            strictMath: strictMath
        )
    }
}
