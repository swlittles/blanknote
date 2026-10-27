import XCTest

/// Text mode (the default): notes look like plain formatted text, and are still saved as Markdown.
final class TextModeUITests: XCTestCase {
    func testTypingInTextModeAndSwitchingToMarkdown() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-theme", "light"]
        app.launch()
        app.buttons["New Note"].firstMatch.tap()
        let editor = app.textViews["editor"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        // A checklist item: the box is drawn, the text underneath is Markdown.
        editor.typeText("Plan\n")
        app.buttons["Checklist"].tap()
        editor.typeText("Milk")
        XCTAssertEqual(editor.value as? String, "Plan\n- [ ] Milk")
        attach(app, "text mode")

        // Deleting back past the start of the item removes its checkbox, as in Apple Notes.
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        XCTAssertEqual(editor.value as? String, "Plan\n")

        editor.typeText("Some **bold** text")
        XCTAssertEqual(editor.value as? String, "Plan\nSome **bold** text")

        // Edit as Markdown (in the More menu) shows the syntax; the text doesn't change.
        app.buttons["Hide Keyboard"].tap()
        app.buttons["More"].firstMatch.tap()
        app.buttons["Edit as Markdown"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Editing as Markdown"].waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "Plan\nSome **bold** text")
        attach(app, "markdown mode")

        app.buttons["More"].firstMatch.tap()
        app.buttons["Edit as Markdown"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Editing as text"].waitForExistence(timeout: 3))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
