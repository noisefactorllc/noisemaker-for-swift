import Foundation

/// Host-shareable WGSL values. Shader booleans are supplied through their declared
/// numeric ABI field (0 or 1); WGSL `bool` itself is not host-shareable.
public indirect enum UniformType: Sendable, Equatable {
    case f32, i32, u32
    case vector(UniformType, count: Int)
    case matrix(columns: Int, rows: Int)
    case array(UniformType, count: Int)
    case structure([UniformField])
}

public struct UniformField: Sendable, Equatable {
    public let name: String
    public let type: UniformType
    public init(name: String, type: UniformType) { self.name = name; self.type = type }
}

public enum UniformError: Error, Equatable {
    case invalidLayout(String)
    case invalidValue(String)
}

public struct UniformLayout: Sendable {
    public struct Field: Sendable {
        public let name: String
        public let type: UniformType
        public let offset: Int
        public let byteCount: Int
        fileprivate let scalars: [Scalar]
    }
    fileprivate struct Scalar: Sendable {
        let type: UniformType
        let offset: Int
    }
    fileprivate struct Shape {
        let alignment: Int
        let size: Int
        let scalars: [Scalar]
    }
    public let fields: [Field]
    public let alignment: Int
    public let byteCount: Int
    public var size: Int { byteCount }
    // WebGPU's baseline uniform binding limit; larger or storage layouts need
    // an explicitly qualified contract rather than an unbounded allocation.
    private static let limit = 65_536

    public init(fields declarations: [UniformField]) throws {
        guard !declarations.isEmpty else { throw UniformError.invalidLayout("empty uniform structure") }
        var names = Set<String>(), fields: [Field] = []
        var cursor = 0, alignment = 1
        for field in declarations {
            guard !field.name.isEmpty, names.insert(field.name).inserted else {
                throw UniformError.invalidLayout("empty or duplicate field name")
            }
            let shape = try Self.shape(field.type)
            cursor = try Self.aligned(cursor, to: shape.alignment)
            fields.append(Field(name: field.name, type: field.type, offset: cursor, byteCount: shape.size, scalars: shape.scalars))
            cursor = try Self.checked(cursor + shape.size)
            alignment = max(alignment, shape.alignment)
        }
        self.fields = fields
        self.alignment = alignment
        self.byteCount = try Self.aligned(cursor, to: alignment)
    }

    private static func checked(_ value: Int) throws -> Int {
        guard value >= 0, value <= limit else { throw UniformError.invalidLayout("uniform exceeds 65536 bytes") }
        return value
    }
    private static func aligned(_ value: Int, to alignment: Int) throws -> Int {
        try checked((value + alignment - 1) / alignment * alignment)
    }
    private static func shape(_ type: UniformType) throws -> Shape {
        switch type {
        case .f32, .i32, .u32:
            return Shape(alignment: 4, size: 4, scalars: [Scalar(type: type, offset: 0)])
        case .vector(let scalar, let count):
            guard [.f32, .i32, .u32].contains(scalar), (2...4).contains(count) else {
                throw UniformError.invalidLayout("vector requires 2 to 4 scalar elements")
            }
            return Shape(alignment: count == 2 ? 8 : 16, size: count * 4,
                         scalars: (0..<count).map { Scalar(type: scalar, offset: $0 * 4) })
        case .matrix(let columns, let rows):
            guard (2...4).contains(columns), (2...4).contains(rows) else {
                throw UniformError.invalidLayout("matrix requires 2 to 4 rows and columns")
            }
            let column = try shape(.vector(.f32, count: rows))
            let stride = try aligned(column.size, to: column.alignment)
            return Shape(alignment: column.alignment, size: columns * stride, scalars: (0..<columns).flatMap { c in
                column.scalars.map { Scalar(type: $0.type, offset: c * stride + $0.offset) }
            })
        case .array(let element, let count):
            guard count > 0, count <= limit / 4 else { throw UniformError.invalidLayout("invalid uniform array count") }
            let item = try shape(element)
            let alignment = max(16, item.alignment)
            let stride = try aligned(item.size, to: alignment)
            let size = try checked(stride * count)
            return Shape(alignment: alignment, size: size, scalars: (0..<count).flatMap { i in
                item.scalars.map { Scalar(type: $0.type, offset: i * stride + $0.offset) }
            })
        case .structure(let declarations):
            let layout = try UniformLayout(fields: declarations)
            let alignment = max(16, layout.alignment)
            return Shape(alignment: alignment, size: try aligned(layout.byteCount, to: alignment), scalars: layout.fields.flatMap { field in
                field.scalars.map { Scalar(type: $0.type, offset: field.offset + $0.offset) }
            })
        }
    }
}

public enum UniformWriter {
    /// Values are flattened in declaration order, with matrices column-major.
    /// Padding is always initialized to zero, and scalar writes are little-endian.
    public static func encode(values: [String: [Double]], layout: UniformLayout) throws -> Data {
        guard Set(values.keys) == Set(layout.fields.map(\.name)) else {
            throw UniformError.invalidValue("uniform fields are missing or unknown")
        }
        var bytes = Data(repeating: 0, count: layout.byteCount)
        for field in layout.fields {
            let values = values[field.name]!
            guard values.count == field.scalars.count else {
                throw UniformError.invalidValue("\(field.name): expected \(field.scalars.count) numeric components")
            }
            for (scalar, value) in zip(field.scalars, values) {
                guard value.isFinite else { throw UniformError.invalidValue("\(field.name): non-finite value") }
                let bits: UInt32
                switch scalar.type {
                case .f32:
                    let converted = Float(value)
                    guard converted.isFinite else { throw UniformError.invalidValue("\(field.name): f32 overflow") }
                    bits = converted.bitPattern
                case .i32:
                    guard value.rounded(.towardZero) == value, value >= Double(Int32.min), value <= Double(Int32.max) else {
                        throw UniformError.invalidValue("\(field.name): invalid i32 value")
                    }
                    bits = UInt32(bitPattern: Int32(value))
                case .u32:
                    guard value.rounded(.towardZero) == value, value >= 0, value <= Double(UInt32.max) else {
                        throw UniformError.invalidValue("\(field.name): invalid u32 value")
                    }
                    bits = UInt32(value)
                default: throw UniformError.invalidLayout("non-scalar write")
                }
                let offset = field.offset + scalar.offset
                for byte in 0..<4 { bytes[offset + byte] = UInt8(truncatingIfNeeded: bits >> (byte * 8)) }
            }
        }
        return bytes
    }
}
