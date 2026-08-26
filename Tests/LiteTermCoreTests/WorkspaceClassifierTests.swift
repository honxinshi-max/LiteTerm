import XCTest
@testable import LiteTermCore

final class WorkspaceClassifierTests: XCTestCase {
    private let classifier = WorkspaceClassifier()

    func testRecognizesEachSupportedWorkspaceFromRootRelativeEvidence() {
        let cases: [([String], WorkspaceKind, Set<WorkspaceIndicator>)] = [
            (["Package.swift", "Sources/App/main.swift"], .swift, [.packageSwift, .swiftSource]),
            (["pyproject.toml", "src/main.py"], .python, [.pyproject, .pythonSource]),
            (["public/index.html", "public/app.js"], .web, [.indexHTML])
        ]

        for (paths, expectedKind, expectedIndicators) in cases {
            let result = classifier.classify(relativePaths: paths)
            XCTAssertEqual(result.kind, expectedKind)
            XCTAssertEqual(result.indicators, expectedIndicators)
        }
    }

    func testConflictingSupportedIndicatorsRequireSessionChoice() {
        let result = classifier.classify(relativePaths: [
            "Package.swift",
            "main.py",
            "index.html"
        ])

        XCTAssertEqual(result.kind, .ambiguous)
        XCTAssertEqual(result.candidates, [.swift, .python, .web])
    }

    func testStaticIndexRemainsRunnableWhenPackageJSONIsPresent() {
        let result = classifier.classify(relativePaths: ["index.html", "package.json"])

        XCTAssertEqual(result.kind, .web)
        XCTAssertEqual(result.candidates, [.web, .nodeRequired])
    }

    func testPackageJSONWithoutStaticIndexRequiresNode() {
        let result = classifier.classify(relativePaths: ["package.json", "src/app.js"])

        XCTAssertEqual(result.kind, .nodeRequired)
        XCTAssertEqual(result.candidates, [.nodeRequired])
    }

    func testUnknownFilesAreUnsupported() {
        let result = classifier.classify(relativePaths: ["README.md", "notes.txt"])

        XCTAssertEqual(result.kind, .unsupported)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.indicators.isEmpty)
    }
}
