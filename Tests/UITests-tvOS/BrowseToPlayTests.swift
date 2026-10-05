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

        let poster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'poster.movie:'")).element(boundBy: 0)
        XCTAssertTrue(poster.waitForExistence(timeout: 20), "Home should show demo posters")

        // Walk focus down from the tab bar until a movie poster has it. Counting presses is racy on a cold first launch.
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        var presses = 0
        while !focused.identifier.hasPrefix("poster.movie:"), presses < 8 {
            remote.press(.down)
            presses += 1
            sleep(1)
        }
        XCTAssertTrue(focused.identifier.hasPrefix("poster.movie:"), "focus should reach a movie poster, got \(focused.identifier)")
        remote.press(.select)

        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "detail page should open")
        let player = app.otherElements["player.host"]
        let searching = app.otherElements["picker.searching"]
        // The detail page animates in and the first Select can land before focus settles. Wait for focus, press, and retry once if
        // neither the stream search nor the player showed up.
        for attempt in 1...3 where !(player.exists || searching.exists) {
            let deadline = Date().addingTimeInterval(10)
            while !play.hasFocus, Date() < deadline { sleep(1) }
            sleep(1)
            remote.press(.select)
            _ = searching.waitForExistence(timeout: 6) || player.waitForExistence(timeout: 1)
            if attempt == 3 { break }
        }
        let opened = player.waitForExistence(timeout: 60)
        if !opened { print("UI DUMP:\n" + app.debugDescription) }
        XCTAssertTrue(opened, "player should open after auto-select")
        sleep(8)
        remote.press(.menu)

        sleep(3)
        // Menu leaves the player; depending on the stack it lands on detail or Home.
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue.'")).firstMatch
        if !resume.waitForExistence(timeout: 8) {
            XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 5), "Menu should leave the player")
            remote.press(.menu)
        }
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "Continue Watching should show the title")
    }
}
