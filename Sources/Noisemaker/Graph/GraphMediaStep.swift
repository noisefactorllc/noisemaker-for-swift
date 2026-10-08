import Foundation

/// A host-owned media texture identified by the original DSL step, independent
/// of the graph's output dimensions. Texture contents remain owned by the host.
public struct GraphMediaStep: Sendable {
    public let textureId:String
    public let uniform:String
    public let stepIndex:Int
    public let effect:String

    static func decode(_ raw:GraphValue?) throws -> [GraphMediaStep] {
        guard let values = raw?.arrayValue else {throw GraphDiagnostic.invalid("graph mediaSteps must be an array")}
        var ids = Set<String>()
        return try values.map { value in
            guard let fields = value.objectFields,
                  Set(fields.map(\.name)) == ["textureId","uniform","stepIndex","effect"],
                  let texture = value.field("textureId")?.stringValue,
                  let uniform = value.field("uniform")?.stringValue,
                  !uniform.isEmpty,
                  let rawIndex = value.field("stepIndex")?.numberValue,
                  let index = Int(exactly:rawIndex), index >= 0,
                  let effect = value.field("effect")?.stringValue, !effect.isEmpty,
                  texture == "\(uniform)_step_\(index)", ids.insert(texture).inserted else {
                throw GraphDiagnostic.invalid("graph mediaSteps has an invalid or duplicate binding")
            }
            return GraphMediaStep(textureId:texture,uniform:uniform,stepIndex:index,effect:effect)
        }
    }
    func isReferenced(by passes:[GraphPass]) -> Bool {
        passes.contains { pass in
            pass.raw.field("stepIndex")?.numberValue == Double(stepIndex) &&
            pass.raw.field("effectKey")?.stringValue == effect &&
            pass.inputs.contains {$0.key == uniform && $0.value.stringValue == textureId}
        }
    }
}
