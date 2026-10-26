import XCTest

/// The iPad layout ("BlankNote iPad"): with the sidebar showing, the list and the open note take
/// turns like on the iPhone; with it hidden, they sit side by side.
final class IPadLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout") }
    }

    func testSidebarShowsTheListOrTheNoteAndHidingItShowsBoth() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-theme", "light"]
        app.launch()

        let row = app.staticTexts["Groceries"].firstMatch
        let editor = app.textViews["editor"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All Notes"].firstMatch.exists, "the sidebar is showing")
        XCTAssertFalse(editor.exists, "no note next to the list while the sidebar shows")
        snapshot(app, "1 sidebar and list")

        // Opening a note takes the list's place; Back brings the list back.
        row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertFalse(row.isHittable, "the note replaced the list")
        snapshot(app, "2 sidebar and note")

        // Hiding the sidebar puts the list and the note side by side.
        sidebarButton(app).tap()
        XCTAssertTrue(waitFor { row.isHittable && editor.isHittable }, "list and note side by side")
        snapshot(app, "3 list and note")

        // Showing it again goes back to one at a time, still on the same note.
        sidebarButton(app).tap()
        XCTAssertTrue(waitFor { !row.isHittable && editor.isHittable })
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(waitFor { row.isHittable && !editor.exists }, "back to the list")
    }

    private func sidebarButton(_ app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["ToggleSidebar"].firstMatch
        if button.exists { return button }
        return app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitFor(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
