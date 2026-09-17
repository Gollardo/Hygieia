import XCTest

final class HygieiaAppUITests: XCTestCase {
    @MainActor
    func testBrandedEmptyStateIsReachable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows["Hygieia"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["scanStateTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["LOCAL DISKS"].exists)
        XCTAssertTrue(app.buttons["Choose a Folder…"].exists)
    }

    @MainActor
    func testWholeMacHelpAndScopeAreReachableWithoutGrantingAccess() {
        let app = XCUIApplication()
        app.launch()
        let command = app.buttons["Scan This Mac…"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.click()
        XCTAssertTrue(app.staticTexts["Scan This Mac"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Full Disk Access Settings"].exists)
        XCTAssertTrue(app.buttons["Scan Selected Roots…"].exists)
        XCTAssertTrue(app.staticTexts["wholeMacStatus"].exists)
        app.buttons["Done"].click()
        XCTAssertTrue(app.buttons["Choose a Folder…"].exists)
    }

    @MainActor
    func testNativePickerCancellationReturnsToSourceSelection() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Choose a Folder…"].click()
        let cancel = app.buttons["CancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.click()
        XCTAssertTrue(app.buttons["Choose a Folder…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose a Folder…"].isEnabled)
        XCTAssertFalse(app.buttons["scanCoverage"].exists)
    }
}
