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
