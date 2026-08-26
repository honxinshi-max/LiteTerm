import Foundation
import XCTest
import LiteTermPythonBridge
@testable import LiteTerm

final class PythonPrivacyBoundaryTests: XCTestCase {
    func testUnavailableRuntimeCannotExecuteAdversarialSource() {
        XCTAssertFalse(LTIsPythonRuntimeAvailable())
        var configuration = LTPythonConfiguration()
        let runtime = LTCreatePythonRuntime(&configuration, nil, nil)
        XCTAssertNil(runtime)
        XCTAssertEqual(LTGetPythonLastError(), LT_PYTHON_ERROR_RUNTIME_UNAVAILABLE)
    }

    func testPolicyRejectsProcessSocketNativeAndEscapingPaths() {
        for event in [
            "subprocess.Popen", "multiprocessing.Process", "socket.__new__",
            "ctypes.dlopen", "os.system", "os.exec", "os.fork"
        ] {
            XCTAssertTrue(event.withCString(LTIsDeniedPythonAuditEvent), event)
        }
        for path in [
            "../outside.py", "/private/source.py", ".hidden.py", "native.so",
            "native.dylib", "bundle.framework", "cached.pyc"
        ] {
            XCTAssertFalse(path.withCString(LTIsSafePythonRelativePath), path)
        }
        for module in ["ctypes", "socket", "subprocess", "multiprocessing", "os", "pathlib"] {
            XCTAssertFalse(module.withCString(LTIsAllowedPythonImport), module)
        }
    }
}
