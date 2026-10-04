import XCTest

@MainActor
final class SetupSmokeTests: XCTestCase {
    func testSetupScreenAppearsWithoutAKey() {
        let app = XCUIApplication()
        // Clears any TorBox key left in the simulator Keychain so the setup screen is deterministic.
        app.launchArguments += ["-uitest-reset"]
        app.launch()
        XCTAssertTrue(app.staticTexts["setup.title"].waitForExistence(timeout: 20))
    }
}
