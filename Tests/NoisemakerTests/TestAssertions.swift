import Testing

// Keep oracle loops concise while recording failures in Swift Testing at the
// calling assertion, including errors thrown while evaluating an expression.
func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
    _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let a = try actual(); let e = try expected(); #expect(a == e, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, Comment(rawValue: message), sourceLocation: sourceLocation) }
}
func expectEqual<T: BinaryFloatingPoint>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
    accuracy: T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let a = try actual(); let e = try expected(); #expect(abs(a - e) <= accuracy, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, Comment(rawValue: message), sourceLocation: sourceLocation) }
}
func expectNotEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
    _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let a = try actual(); let e = try expected(); #expect(a != e, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, Comment(rawValue: message), sourceLocation: sourceLocation) }
}
func expectTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let result = try value(); #expect(result, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, Comment(rawValue: message), sourceLocation: sourceLocation) }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let result = try value(); #expect(!result, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, Comment(rawValue: message), sourceLocation: sourceLocation) }
}
func expectNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let result = try value(); #expect(result == nil, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, Comment(rawValue: message), sourceLocation: sourceLocation) }
}
func requireValue<T>(_ value: @autoclosure () throws -> T?, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    let result = try value()
    return try #require(result, Comment(rawValue: message), sourceLocation: sourceLocation)
}
func expectThrows<T>(_ expression: @autoclosure () throws -> T, _ message: String = "",
    sourceLocation: SourceLocation = #_sourceLocation, _ handler: (any Error) -> Void = { _ in }) {
    do { _ = try expression(); Issue.record(Comment(rawValue: "Expected error. " + message), sourceLocation: sourceLocation) }
    catch { handler(error) }
}
func recordFailure(_ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
}
func expectAtLeast<T: Comparable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
    _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let a = try actual(); let e = try expected(); #expect(a >= e, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, Comment(rawValue: message), sourceLocation: sourceLocation) }
}
func expectGreater<T: Comparable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
    _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let a = try actual(); let e = try expected(); #expect(a > e, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, Comment(rawValue: message), sourceLocation: sourceLocation) }
}
func expectLess<T: Comparable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
    _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { let a = try actual(); let e = try expected(); #expect(a < e, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, Comment(rawValue: message), sourceLocation: sourceLocation) }
}
