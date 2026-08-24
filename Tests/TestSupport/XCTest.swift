public typealias XCTestCaseEntry = (
    testCaseClass: XCTestCase.Type,
    allTests: [(String, (XCTestCase) throws -> Void)]
)

open class XCTestCase {
    public required init() {}
}

public func testCase<T: XCTestCase>(
    _ allTests: [(String, (T) throws -> Void)]
) -> XCTestCaseEntry {
    (
        testCaseClass: T.self,
        allTests: allTests.map { name, test in
            (name, { instance in
                try test(instance as! T)
            })
        }
    )
}

public func XCTMain(_ testCases: [XCTestCaseEntry]) {
    var failures: [String] = []

    for testCaseEntry in testCases {
        for (name, test) in testCaseEntry.allTests {
            do {
                try test(testCaseEntry.testCaseClass.init())
            } catch {
                failures.append("\(name): \(error)")
            }
        }
    }

    guard failures.isEmpty else {
        fatalError(failures.joined(separator: "\n"))
    }
}

public func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () -> T,
    _ expression2: @autoclosure () -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard expression1() == expression2() else {
        fatalError("XCTAssertEqual failed at \(file):\(line): \(message())")
    }
}

public func XCTAssertNil<T>(
    _ expression: @autoclosure () -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard expression() == nil else {
        fatalError("XCTAssertNil failed at \(file):\(line): \(message())")
    }
}

public func XCTFail(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    fatalError("XCTFail at \(file):\(line): \(message())")
}
