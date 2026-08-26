import XCTest

final class WorkspaceFlowUITests: XCTestCase {
    func testWorkspaceSurfaceKeepsTerminalProblemsAndPortsAvailable() {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing-workspace")
        app.launch()

        app.tabBars.buttons["Local Workspace"].tap()

        XCTAssertTrue(app.otherElements["Workspace screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Lightweight Local Workspace"].exists)
        XCTAssertTrue(app.buttons["Workspace check"].exists)
        XCTAssertTrue(app.buttons["Workspace test"].exists)
        XCTAssertTrue(app.buttons["Workspace run"].exists)
        XCTAssertTrue(app.buttons["Workspace stop"].exists)
        XCTAssertTrue(app.segmentedControls["Workspace bottom panel"].exists)

        app.segmentedControls["Workspace bottom panel"].buttons["Ports"].tap()
        XCTAssertTrue(app.staticTexts["No verified service port"].exists)
        app.segmentedControls["Workspace bottom panel"].buttons["Problems"].tap()
        XCTAssertTrue(app.otherElements["Workspace problems panel"].exists)
        app.segmentedControls["Workspace bottom panel"].buttons["Terminal"].tap()
        XCTAssertTrue(app.otherElements["Terminal view"].exists)
    }

    func testWorkspaceAdaptsToPortraitBrowserSheetAndLandscapeColumns() {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing-workspace")
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        app.tabBars.buttons["Local Workspace"].tap()

        XCTAssertTrue(app.buttons["Workspace files"].waitForExistence(timeout: 3))
        app.buttons["Workspace files"].tap()
        XCTAssertTrue(app.otherElements["Workspace file browser"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.otherElements["Workspace editor column"].waitForExistence(timeout: 3))
    }

    func testUnsavedDraftRequiresExplicitDiscardBeforeLeavingWorkspace() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-workspace"]
        app.launch()

        app.tabBars.buttons["Local Workspace"].tap()
        XCTAssertTrue(app.otherElements["Workspace file browser"].waitForExistence(timeout: 3))
        app.buttons["index.html"].tap()

        let editor = app.textViews["Workspace code editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText(" unsaved")

        app.buttons["style.css"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 2))
        app.buttons["Keep Editing"].tap()
        XCTAssertTrue(editor.exists)

        app.tabBars.buttons["Terminal"].tap()
        XCTAssertTrue(app.alerts["Discard unsaved workspace changes?"].waitForExistence(timeout: 2))
    }
}
