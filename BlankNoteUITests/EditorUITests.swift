import XCTest

/// Drives the real editor on the iPhone simulator ("BlankNote iPhone", an iPhone 17 Pro), using the
/// demo notes from `-demo`.
final class EditorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-theme", "light"] + arguments
        app.launch()
        return app
    }

    func testTypingContinuesAndEndsListsThenRenamesTheNote() {
        let app = launch([])
        app.buttons["New Note"].firstMatch.tap()
        let editor = app.textViews["editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "a new note starts with the keyboard up")

        editor.typeText("Packing\n- Socks\nHat\n\nDone")
        XCTAssertEqual(editor.value as? String, "Packing\n- Socks\n- Hat\nDone")

        // Back to the list: the note was saved and took its title from the first line.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Packing"].waitForExistence(timeout: 3))
    }

    func testKeyboardBarFitsOnScreenAndFormats() {
        let app = launch([])
        app.buttons["New Note"].firstMatch.tap()
        let editor = app.textViews["editor"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        // Every button is fully on screen (none scrolled out of view on an iPhone 17 Pro), from
        // Checklist at the start to Hide Keyboard pinned at the end.
        let screen = app.windows.firstMatch.frame
        let hide = app.buttons["Hide Keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 2))
        XCTAssertTrue(screen.contains(hide.frame), "Hide Keyboard at \(hide.frame) is outside \(screen)")
        for label in ["Checklist", "Bulleted List", "Heading", "Bold", "Italic", "Code", "Outdent", "Indent"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists, label)
            XCTAssertGreaterThanOrEqual(button.frame.minX, screen.minX, label)
            XCTAssertLessThanOrEqual(button.frame.maxX, hide.frame.minX, "\(label) at \(button.frame) runs under Hide Keyboard")
            XCTAssertTrue(button.isHittable, label)
        }

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "keyboard bar"
        shot.lifetime = .keepAlways
        add(shot)

        editor.typeText("Plan")
        app.buttons["Checklist"].tap()
        XCTAssertEqual(editor.value as? String, "- [ ] Plan")
        app.buttons["Hide Keyboard"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1))
    }

    func testTappingACheckboxTicksItWithoutTheKeyboard() {
        let app = launch(["-open", "Groceries"])
        let editor = app.textViews["editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists, "opening a note doesn't bring up the keyboard")

        // "[ ] Oat milk" is the first line under the title.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 49, dy: 186)).tap()
        XCTAssertTrue((editor.value as? String)?.contains("- [x] Oat milk") == true, "\(editor.value ?? "")")
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1), "ticking a box doesn't start editing")

        // Tapping it again unticks it.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 49, dy: 186)).tap()
        XCTAssertTrue((editor.value as? String)?.contains("- [ ] Oat milk") == true)
    }

    func testSearchFindsNotesByContent() {
        let app = launch([])
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("kubectl rollout")
        XCTAssertTrue(app.staticTexts["No Results for “kubectl rollout”"].waitForExistence(timeout: 3)
                      || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No Results'")).firstMatch.exists)
        search.buttons.firstMatch.tap()
        search.typeText("parmesan")
        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 3))
    }
}
