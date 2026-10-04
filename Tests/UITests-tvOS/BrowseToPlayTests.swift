import XCTest

/// P2 gate, automated: browse to play and back using only the remote. Uses demo titles and the debug dev media source
/// (`python3 rangeserver.py` serving the test files on 127.0.0.1:8000).
@MainActor
final class BrowseToPlayTests: XCTestCase {
    func testBrowseToPlayThenContinueWatching() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-reset", "-dev-media-url", "http://127.0.0.1:8000"]
        app.launch()
        let remote = XCUIRemote.shared

        let poster = app.buttons["poster.movie:900001"]
        XCTAssertTrue(poster.waitForExistence(timeout: 20), "Home should show demo posters")

        // Tab bar -> TMDB notice -> first poster: the focus path on a demo Home is fixed.
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        remote.press(.select)

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "detail page should open")
        sleep(1)
        remote.press(.select)

        let player = app.otherElements["player.host"]
        XCTAssertTrue(player.waitForExistence(timeout: 60), "player should open after auto-select")
        sleep(8)
        remote.press(.menu)

        // Menu leaves the player; depending on the stack it lands on detail or Home.
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue.'")).firstMatch
        if !resume.waitForExistence(timeout: 8) {
            XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 5), "Menu should leave the player")
            remote.press(.menu)
        }
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "Continue Watching should show the title")
    }
}
