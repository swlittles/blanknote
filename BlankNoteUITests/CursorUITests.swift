import XCTest

/// Tapping into a note's text puts the cursor there, and typing stays there through autosaves (which
/// rename the file when the title changes).
final class CursorUITests: XCTestCase {
    func testTappingTheTitleTypesInTheTitle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-theme", "light", "-open", "Trip ideas"]
        app.launch()
        let editor = app.textViews["editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        func tap(_ x: CGFloat, _ y: CGFloat) {
            editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        }

        // A tap on the text starts editing there…
        tap(340, 145)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "tapping the text starts editing")
        editor.typeText("!")
        XCTAssertTrue((editor.value as? String ?? "").contains("Kyoto, but not in peak season!"))

        // …and, while editing, moves the cursor: below the text puts it at the end, the title in the title.
        tap(200, 400)
        tap(300, 30)
        for letter in ["s", "!", "x"] {
            editor.typeText(letter)
            // Long enough for the autosave, which renames the file to match the title.
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        }
        let text = editor.value as? String ?? ""
        XCTAssertTrue(text.hasPrefix("# Trip ideass!x\n"), "typed into the title: \(text.debugDescription)")
        XCTAssertTrue(text.hasSuffix("Drive the coast road"), "nothing typed at the end: \(text.debugDescription)")
    }
}
