import XCTest

/// The list on simulated recordings: the search drawer, and a row that
/// opens its recording.
@MainActor
final class LibraryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The link sits behind the row, so a tap on the row itself must open
    /// the recording.
    func testTappingARowOpensTheRecording() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLIO_SIMULATE"] = "1"
        app.launch()

        let row = app.staticTexts["Standup notes"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.staticTexts["Recorded"].waitForExistence(timeout: 5),
                      "the detail view opened from the row")

        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 5),
                      "the X takes the recording away again")
    }

    /// The search field lives in the navigation bar's drawer: out of the
    /// way once the list scrolls, back when the list is pulled down.

    func testSearchHidesOnScrollAndReturnsOnPull() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLIO_SIMULATE"] = "1"
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 10))
        XCTAssertTrue(search.exists, "the field is there at rest")

        app.swipeUp()
        let hidden = waitUntil { !search.exists || !search.isHittable }
        XCTAssertTrue(hidden, "scrolling the list puts the field away")

        app.swipeDown()
        app.swipeDown()
        let back = waitUntil { search.exists && search.isHittable }
        XCTAssertTrue(back, "pulling the list down brings the field back")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
