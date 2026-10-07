public enum GraphDiagnostic: Error, CustomStringConvertible {
    case invalid(String)
    case unsupported(String)
    case missing(String)

    public var description: String {
        switch self {
        case .invalid(let detail): return "Invalid exported graph: \(detail)"
        case .unsupported(let detail): return "Unsupported graph semantics: \(detail)"
        case .missing(let detail): return "Missing graph resource: \(detail)"
        }
    }
}
