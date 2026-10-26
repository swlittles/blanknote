import XCTest

/// Keyboard shortcuts (iPad, with real hardware-keyboard presses) and in-app notifications.
final class ShortcutsAndToastsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-resetShortcuts", "-theme", "light"] + arguments
        app.launch()
        return app
    }

    func testDeletingANoteOffersUndo() {
        let app = launch()
        let row = app.staticTexts["Groceries"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()

        XCTAssertTrue(app.otherElements["toast"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Moved “Groceries” to Recently Deleted"].exists)
        XCTAssertFalse(app.staticTexts["Groceries"].exists)

        app.buttons["toast.action"].tap()
        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 3), "Undo puts the note back")
        XCTAssertFalse(app.otherElements["toast"].exists)
    }

    func testKeyboardShortcutsWorkAndCanBeChanged() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Needs an iPad with a hardware keyboard") }
        let app = launch(["-open", "Welcome to BlankNote"])
        let editor = app.textViews["editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        // iPadOS sets up the app's key commands a moment after launch.
        sleep(2)

        // ⌘N: a new, empty note with the cursor in it.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitFor { (editor.value as? String) == "" }, "⌘N opens a new note")
        editor.typeText("Made with a shortcut")
        XCTAssertEqual(editor.value as? String, "Made with a shortcut")

        // Pin it with ⇧⌘P: the in-app notification says so.
        app.typeKey("p", modifierFlags: [.shift, .command])
        XCTAssertTrue(app.staticTexts["Pinned “Made with a shortcut”"].waitForExistence(timeout: 3))

        // Move New Note to ⌥⌘J in Settings.
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["keyboardShortcuts"].firstMatch.tap()
        let recorder = app.buttons["shortcut.newNote"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 3))
        XCTAssertTrue(recorder.label.hasSuffix("⌘N"), recorder.label)
        // The row is one accessibility element; the shortcut pill is at its trailing end.
        recorder.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        XCTAssertTrue(waitFor { recorder.label.hasSuffix("Type Shortcut…") })
        app.typeKey("j", modifierFlags: [.option, .command])
        XCTAssertTrue(waitFor { recorder.label.hasSuffix("⌥⌘J") }, "recorded: \(recorder.label)")
        // Settings' own Back (the open note behind the sheet has one too).
        app.navigationBars["Keyboard Shortcuts"].buttons["BackButton"].tap()
        app.buttons["Done"].firstMatch.tap()

        // ⌘N no longer makes a note; ⌥⌘J does.
        editor.tap()
        app.typeKey("n", modifierFlags: .command)
        sleep(1)
        XCTAssertEqual(editor.value as? String, "Made with a shortcut", "⌘N does nothing now")
        app.typeKey("j", modifierFlags: [.option, .command])
        XCTAssertTrue(waitFor { (editor.value as? String) == "" }, "⌥⌘J opens a new note")
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
