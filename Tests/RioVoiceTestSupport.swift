import Foundation

extension TestSupport {
    /// `expectEqual` with a message naming the case, for the table-driven Rio voice tests.
    static func expectEqualNamed<T: Equatable>(
        _ actual: @autoclosure () -> T,
        _ expected: @autoclosure () -> T,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualValue = actual()
        let expectedValue = expected()
        expect(
            actualValue == expectedValue,
            "\(message): expected \(String(describing: expectedValue)), got \(String(describing: actualValue))",
            file: file,
            line: line
        )
    }
}
