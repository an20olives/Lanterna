import XCTest

/// Real data (the dev TMDB token is seeded), so this only runs on a dev build.
@MainActor
final class HeroFocusTests: XCTestCase {
    private func focusedHeroButton(_ app: XCUIApplication) -> String {
        let dump = app.debugDescription
        for id in ["hero.play", "hero.details"] {
            if dump.split(separator: "\n").contains(where: { $0.contains("identifier: '\(id)'") && $0.contains("Focused") }) { return id }
        }
        return "none"
    }

    func testDownFromTabBarLandsOnHeroPlayAndRightReachesDetails() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-hero"]
        app.launch()
        let play = app.buttons["hero.play"]
        try XCTSkipUnless(play.waitForExistence(timeout: 40), "needs real TMDB data")
        sleep(2)
        let remote = XCUIRemote.shared
        remote.press(.down); sleep(2)
        var landed = focusedHeroButton(app)
        XCTAssertNotEqual(landed, "none", "coming down from the tab bar should land on the hero, not Continue Watching")
        // Moving between the two buttons must move focus, not change the slide (and lose focus).
        if landed == "hero.details" { remote.press(.left); sleep(2); landed = focusedHeroButton(app); XCTAssertEqual(landed, "hero.play") }
        remote.press(.right); sleep(2)
        XCTAssertEqual(focusedHeroButton(app), "hero.details", "Right should move to Details, not scroll the slide")
        remote.press(.select); sleep(5)
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 15), "Details should open the title page")
    }
}
