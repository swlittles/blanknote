import XCTest

/// Screenshots of the note list for checking the layout by eye (top, and scrolled to the end), plus
/// a check that the last note can be scrolled clear of the search bar.
final class ListLayoutUITests: XCTestCase {
    func testLastNoteScrollsClearOfTheSearchBar() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-manyNotes", "-theme", "dark"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Groceries"].firstMatch.waitForExistence(timeout: 5))
        attach(app, "list top")

        let list = app.collectionViews.firstMatch
        for _ in 0..<12 { list.swipeUp() }
        attach(app, "list end")

        // The last note (the oldest filler) sits fully above the search field.
        let last = app.staticTexts["Filler 40"].firstMatch
        let search = app.searchFields.firstMatch
        XCTAssertTrue(last.exists && search.exists)
        XCTAssertLessThanOrEqual(last.frame.maxY, search.frame.minY, "last row \(last.frame) under search \(search.frame)")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
