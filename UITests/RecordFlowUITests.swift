import XCTest

/// The real app on a simulator, through the real recorder: tap Record,
/// let the Mac's microphone run for a moment, tap Stop, and a recording
/// exists. Nothing here is simulated, which is the point — every other
/// test runs the state machine on a fake microphone.
///
///     xcrun simctl privacy booted grant microphone com.bartbak.clio.ios
///     xcodebuild test -project Clio.xcodeproj -scheme Clio \
///       -only-testing:ClioUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
///
/// Without a model installed the recording is saved as failed with the
/// "no model" message, which is the expected outcome on a fresh
/// simulator; with one, it is transcribed. Either way the row is there.
final class RecordFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecordStopSavesARecording() throws {
        let app = XCUIApplication()
        app.launch()

        // The permission prompt, if the grant above was not run.
        addUIInterruptionMonitor(withDescription: "Microphone") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }

        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "the record button is on the list")
        record.tap()
        app.tap()   // gives the interruption monitor its turn

        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 15),
                      "the microphone started")
        sleep(3)

        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.exists)
        stop.tap()

        // Stop → transcribing → the detail view of the new recording.
        XCTAssertTrue(app.staticTexts["Details"].waitForExistence(timeout: 90),
                      "the recording opened")
        XCTAssertTrue(app.staticTexts["Length"].exists)
        XCTAssertTrue(app.buttons["Play"].exists, "the audio file loaded into the player")

        // Back to the list: the row is there.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 10))
    }
}
