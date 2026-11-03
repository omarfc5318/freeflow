import Foundation

/// Equality assertion with an optional message, for the builder E test files.
enum ETest {
    static func eq<T: Equatable>(
        _ actual: @autoclosure () -> T,
        _ expected: @autoclosure () -> T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualValue = actual()
        let expectedValue = expected()
        TestSupport.expect(
            actualValue == expectedValue,
            "\(message) Expected \(String(describing: expectedValue)), got \(String(describing: actualValue))",
            file: file,
            line: line
        )
    }
}
