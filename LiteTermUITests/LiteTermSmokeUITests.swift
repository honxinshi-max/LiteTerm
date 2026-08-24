import XCTest

final class LiteTermSmokeUITests: XCTestCase {
    func testModeSwitcherAndTouchShortcutsAreAvailable() {
        let app = XCUIApplication()
        app.launch()

        let modePicker = app.segmentedControls["Terminal mode"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 3))
        modePicker.buttons["SSH"].tap()
        XCTAssertTrue(app.staticTexts["Disconnected"].exists)

        for label in ["Esc", "Ctrl", "Tab", "↑", "↓", "←", "→", "/"] {
            XCTAssertTrue(app.buttons["shortcut.\(label)"].exists, "Missing shortcut \(label)")
        }
    }

    func testEditorCanBePresentedWithExplicitSaveAndCancelActions() {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing-open-editor")
        app.launch()

        XCTAssertTrue(app.navigationBars["Editor"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Save"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }
}
