import XCTest
@testable import Noisemaker

final class TranslatorTests: XCTestCase {
    private let valid = "@compute @workgroup_size(1) fn main() {}"

    func testDeterministicTranslationAndOwnedOutput() throws {
        let translator = ShaderTranslator()
        let first = try translator.translate(wgsl: valid, entryPoint: "main", stage: .compute)
        let second = try translator.translate(wgsl: valid, entryPoint: "main", stage: .compute)
        XCTAssertEqual(first.source, second.source)
        XCTAssertTrue(first.source.contains("dawn_entry_point"))
        XCTAssertEqual(first.mslEntryPoint, "dawn_entry_point")
        XCTAssertEqual(first.workgroupSize.0, 1)
        XCTAssertEqual(first.workgroupSize.1, 1)
        XCTAssertEqual(first.workgroupSize.2, 1)
    }

    func testMalformedWGSLReturnsDiagnostic() {
        XCTAssertThrowsError(try ShaderTranslator().translate(
            wgsl: "@compute fn", entryPoint: "main", stage: .compute)) { error in
            guard case TintTranslationError.translationFailed(let message) = error else {
                return XCTFail("Expected a Tint diagnostic, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testDuplicateBindingIsRejectedBeforeTint() {
        let binding = TintBinding(group: 0, binding: 0, kind: .storage, slot: 0)
        XCTAssertThrowsError(try ShaderTranslator().translate(
            wgsl: valid, entryPoint: "main", stage: .compute,
            bindings: [binding, binding])) { error in
            guard case TintTranslationError.invalidInput = error else {
                return XCTFail("Expected binding validation, got \(error)")
            }
        }
    }

    func testStorageSizeMetadataIsPreserved() throws {
        let wgsl = "@group(0) @binding(0) var<storage, read_write> out: array<f32>; @compute @workgroup_size(1) fn main() { out[0] = 1.0; }"
        let size = TintBufferSize(group: 0, binding: 0, index: 0)
        let result = try ShaderTranslator().translate(
            wgsl: wgsl, entryPoint: "main", stage: .compute,
            bindings: [TintBinding(group: 0, binding: 0, kind: .storage, slot: 0)],
            bufferSizes: [size], bufferSizesOffset: 0, immediateSlot: 30)
        XCTAssertEqual(result.bufferSizes, [size])
        XCTAssertEqual(result.bufferSizesOffset, 0)
        XCTAssertEqual(result.immediateSlot, 30)
    }

    func testRequestedStageMustMatchWGSL() {
        XCTAssertThrowsError(try ShaderTranslator().translate(
            wgsl: valid, entryPoint: "main", stage: .fragment))
    }

    func testMissingBindingMapFails() {
        let wgsl = "@group(0) @binding(0) var<uniform> value: f32; @compute @workgroup_size(1) fn main() { let x = value; }"
        XCTAssertThrowsError(try ShaderTranslator().translate(
            wgsl: wgsl, entryPoint: "main", stage: .compute))
    }

    func testDuplicateStorageSizeIndexIsRejected() {
        let sizes = [TintBufferSize(group: 0, binding: 0, index: 0),
                     TintBufferSize(group: 0, binding: 1, index: 0)]
        XCTAssertThrowsError(try ShaderTranslator().translate(
            wgsl: valid, entryPoint: "main", stage: .compute,
            bufferSizes: sizes, bufferSizesOffset: 0)) { error in
            guard case TintTranslationError.invalidInput = error else {
                return XCTFail("Expected size-index validation, got \(error)")
            }
        }
    }

    func testConcurrentCallsProduceSameResult() async throws {
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
        XCTAssertEqual(outputs.count, 8)
        XCTAssertTrue(outputs.allSatisfy { $0 == expected })
    }
}
