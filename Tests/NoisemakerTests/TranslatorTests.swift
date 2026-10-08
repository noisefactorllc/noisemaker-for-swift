import Testing
@testable import Noisemaker

@Suite(.serialized)
struct TranslatorTests {
    private let valid = "@compute @workgroup_size(1) fn main() {}"

    @Test func testDeterministicTranslationAndOwnedOutput() throws {
        let translator = ShaderTranslator()
        let first = try translator.translate(wgsl: valid, entryPoint: "main", stage: .compute)
        let second = try translator.translate(wgsl: valid, entryPoint: "main", stage: .compute)
        expectEqual(first.source, second.source)
        expectTrue(first.source.contains("dawn_entry_point"))
        expectEqual(first.mslEntryPoint, "dawn_entry_point")
        expectEqual(first.workgroupSize.0, 1)
        expectEqual(first.workgroupSize.1, 1)
        expectEqual(first.workgroupSize.2, 1)
    }

    @Test func testMalformedWGSLReturnsDiagnostic() {
        expectThrows(try ShaderTranslator().translate(
            wgsl: "@compute fn", entryPoint: "main", stage: .compute)) { error in
            guard case TintTranslationError.translationFailed(let message) = error else {
                return recordFailure("Expected a Tint diagnostic, got \(error)")
            }
            expectFalse(message.isEmpty)
        }
    }

    @Test func testDuplicateBindingIsRejectedBeforeTint() {
        let binding = TintBinding(group: 0, binding: 0, kind: .storage, slot: 0)
        expectThrows(try ShaderTranslator().translate(
            wgsl: valid, entryPoint: "main", stage: .compute,
            bindings: [binding, binding])) { error in
            guard case TintTranslationError.invalidInput = error else {
                return recordFailure("Expected binding validation, got \(error)")
            }
        }
    }

    @Test func testStorageSizeMetadataIsPreserved() throws {
        let wgsl = "@group(0) @binding(0) var<storage, read_write> out: array<f32>; @compute @workgroup_size(1) fn main() { out[0] = 1.0; }"
        let size = TintBufferSize(group: 0, binding: 0, index: 0)
        let result = try ShaderTranslator().translate(
            wgsl: wgsl, entryPoint: "main", stage: .compute,
            bindings: [TintBinding(group: 0, binding: 0, kind: .storage, slot: 0)],
            bufferSizes: [size], bufferSizesOffset: 0, immediateSlot: 30)
        expectEqual(result.bufferSizes, [size])
        expectEqual(result.bufferSizesOffset, 0)
        expectEqual(result.immediateSlot, 30)
    }

    @Test func testRuntimeStorageWithoutSizeReturnsDiagnostic() {
        for storage in ["array<f32>", "Tail"] {
            let wgsl = "struct Tail { count: u32, values: array<f32> }; @group(0) @binding(0) var<storage, read_write> output: \(storage); @compute @workgroup_size(1) fn main() { " +
                (storage == "Tail" ? "output.values[0] = 1.0;" : "output[0] = 1.0;") + " }"
            expectThrows(try ShaderTranslator().translate(wgsl: wgsl, entryPoint: "main", stage: .compute,
                bindings: [TintBinding(group:0,binding:0,kind:.storage,slot:0)])) { error in
                expectTrue(String(describing:error).contains("buffer-size metadata"))
            }
        }
    }

    @Test func testRequestedStageMustMatchWGSL() {
        expectThrows(try ShaderTranslator().translate(
            wgsl: valid, entryPoint: "main", stage: .fragment))
    }

    @Test func testMissingBindingMapFails() {
        let wgsl = "@group(0) @binding(0) var<uniform> value: f32; @compute @workgroup_size(1) fn main() { let x = value; }"
        expectThrows(try ShaderTranslator().translate(
            wgsl: wgsl, entryPoint: "main", stage: .compute))
    }

    @Test func testDuplicateStorageSizeIndexIsRejected() {
        let sizes = [TintBufferSize(group: 0, binding: 0, index: 0),
                     TintBufferSize(group: 0, binding: 1, index: 0)]
        expectThrows(try ShaderTranslator().translate(
            wgsl: valid, entryPoint: "main", stage: .compute,
            bufferSizes: sizes, bufferSizesOffset: 0)) { error in
            guard case TintTranslationError.invalidInput = error else {
                return recordFailure("Expected size-index validation, got \(error)")
            }
        }
    }

    @Test func testConcurrentCallsProduceSameResult() async throws {
        let wgsl = valid
        let expected = try ShaderTranslator().translate(wgsl: wgsl, entryPoint: "main", stage: .compute).source
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try ShaderTranslator().translate(wgsl: wgsl, entryPoint: "main", stage: .compute).source
                }
            }
            var results: [String] = []
            for try await result in group { results.append(result) }
            return results
        }
        expectEqual(outputs.count, 8)
        expectTrue(outputs.allSatisfy { $0 == expected })
    }
}
