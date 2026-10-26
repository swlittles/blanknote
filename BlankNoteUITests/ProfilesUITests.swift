import XCTest

/// Profiles on iPhone: switching changes the notes and the colours; new profiles start empty;
/// renaming shows up in the switcher.
final class ProfilesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-resetShortcuts", "-theme", "light"]
        app.launch()
        return app
    }

    /// From the note list on iPhone, back to the sidebar where the profile switcher is.
    private func showSidebar(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["BackButton"]
        if back.waitForExistence(timeout: 2) { back.tap() }
        XCTAssertTrue(app.buttons["profileSwitcher"].waitForExistence(timeout: 3))
    }

    private func switchProfile(to name: String, in app: XCUIApplication) {
        showSidebar(app)
        app.buttons["profileSwitcher"].tap()
        app.buttons[name].firstMatch.tap()
    }

    func testSwitchingProfilesChangesNotesAndColours() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 5), "starts in Personal")
        showSidebar(app)
        XCTAssertEqual(app.buttons["profileSwitcher"].label, "Profile: Personal")
        let personalTint = sidebarRedMinusBlue(app)
        XCTAssertGreaterThan(personalTint, 4, "Personal's sidebar is Claude's warm beige")

        switchProfile(to: "Acme Corp", in: app)
        XCTAssertTrue(app.staticTexts["Switched to Acme Corp"].waitForExistence(timeout: 3))
        showSidebar(app)
        XCTAssertEqual(app.buttons["profileSwitcher"].label, "Profile: Acme Corp")
        XCTAssertTrue(app.staticTexts["Engineering"].exists, "Acme's folders")
        XCTAssertFalse(app.staticTexts["Travel"].exists, "not Personal's")
        XCTAssertLessThan(sidebarRedMinusBlue(app), personalTint - 4, "Acme's blue theme tints the sidebar")

        app.staticTexts["All Notes"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Q4 planning"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Groceries"].exists)

        // Search only looks in the current profile.
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("parmesan")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No Results'")).firstMatch.waitForExistence(timeout: 3))
    }

    func testCreatingAndRenamingAProfile() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Groceries"].waitForExistence(timeout: 5))
        showSidebar(app)
        app.buttons["profileSwitcher"].tap()
        app.buttons["New Profile…"].firstMatch.tap()

        let name = app.textFields["profileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("Company2")
        app.buttons["theme.Plum"].tap()
        app.buttons["Create"].tap()

        XCTAssertTrue(app.staticTexts["Switched to Company2"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No Notes"].waitForExistence(timeout: 3), "a new profile starts empty")

        // Rename it in Settings › Profiles.
        showSidebar(app)
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["profilesSettings"].firstMatch.tap()
        app.buttons["profile.Company2"].firstMatch.tap()
        let field = app.textFields["profileName"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "Contoso\n")
        XCTAssertTrue(app.textFields["profileName"].exists, "renaming the open profile keeps Settings open")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["profile.Contoso"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["profileSwitcher"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["profileSwitcher"].label, "Profile: Contoso")
    }

    /// Red minus blue (0…255) of the sidebar's background, sampled down the margin left of the
    /// rows: positive for warm themes, negative for blue ones.
    private func sidebarRedMinusBlue(_ app: XCUIApplication) -> Double {
        sleep(1)
        guard let source = app.screenshot().image.cgImage else { return 0 }
        // Redraw into plain 8-bit sRGB RGBA: screenshots may come in a wider format.
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Row 0 of the buffer is the top of the image.
        let x = width / 80
        var total = 0.0
        var count = 0
        for y in stride(from: height * 4 / 10, to: height * 9 / 10, by: 8) {
            let offset = (y * width + x) * 4
            total += Double(pixels[offset]) - Double(pixels[offset + 2])
            count += 1
        }
        return total / Double(count)
    }
}
