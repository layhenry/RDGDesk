import XCTest

func assertSensitiveEqual<Value: Equatable>(
    _ actual: @autoclosure () -> Value,
    _ expected: @autoclosure () -> Value,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard actual() == expected() else {
        XCTFail("Sensitive values differ", file: file, line: line)
        return
    }
}

func assertSensitiveNil<Value>(
    _ actual: @autoclosure () -> Value?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard actual() == nil else {
        XCTFail("Expected sensitive value to be absent", file: file, line: line)
        return
    }
}
