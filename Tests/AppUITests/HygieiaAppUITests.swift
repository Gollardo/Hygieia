import XCTest

final class HygieiaAppUITests: XCTestCase {
    @MainActor
    func testBrandedEmptyStateIsReachable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows["Hygieia"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["See the space inside your Mac."].exists)
        XCTAssertTrue(app.staticTexts["LOCAL DISKS"].exists)
        XCTAssertTrue(app.buttons["Choose a Folder…"].exists)
    }
}
