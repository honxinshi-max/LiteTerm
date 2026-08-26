import XCTest
import LiteTermPythonBridge

final class LiteTermPythonBridgeTests: XCTestCase {
    func testUnavailableArtifactFailsClosedWithoutCreatingRuntime() {
        guard !LTIsPythonRuntimeAvailable() else {
            return XCTFail("Run the artifact-backed bridge suite when embedded Python is enabled.")
        }
        var configuration = LTPythonConfiguration()
        XCTAssertNil(LTCreatePythonRuntime(&configuration, nil, nil))
        XCTAssertEqual(LTGetPythonLastError(), LT_PYTHON_ERROR_RUNTIME_UNAVAILABLE)
    }

    func testStaticPolicyRejectsEscapeProcessSocketAndNativeExtension() {
        XCTAssertTrue("package/main.py".withCString(LTIsSafePythonRelativePath))
        XCTAssertFalse("../private.py".withCString(LTIsSafePythonRelativePath))
        XCTAssertFalse("module.so".withCString(LTIsSafePythonRelativePath))
        XCTAssertTrue("socket.__new__".withCString(LTIsDeniedPythonAuditEvent))
        XCTAssertTrue("subprocess.Popen".withCString(LTIsDeniedPythonAuditEvent))
        XCTAssertTrue("json".withCString(LTIsAllowedPythonImport))
        XCTAssertFalse("ctypes".withCString(LTIsAllowedPythonImport))
    }
}
