import XCTest

/// The theme picker in Settings changes the running app, both ways.
final class ThemeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testThemePickerSwitchesBetweenDarkAndLight() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-theme", "dark"]
        app.launch()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThan(backgroundBrightness(app), 0.3, "starts dark")

        pickTheme("Light", in: app)
        XCTAssertGreaterThan(backgroundBrightness(app), 0.8, "Light applies straight away")

        pickTheme("Dark", in: app)
        XCTAssertLessThan(backgroundBrightness(app), 0.3, "and Dark brings it back")

        // The choice is saved: a relaunch without -theme keeps it.
        app.terminate()
        app.launchArguments = ["-demo"]
        app.launch()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThan(backgroundBrightness(app), 0.3)
    }

    private func pickTheme(_ name: String, in app: XCUIApplication) {
        // On iPhone, Settings lives on the sidebar, one level up from All Notes.
        let back = app.navigationBars.buttons["BackButton"]
        if back.exists { back.tap() }
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["themePicker"].firstMatch.tap()
        app.buttons[name].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        // Back to All Notes, where the brightness is sampled.
        app.staticTexts["All Notes"].firstMatch.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        sleep(1)
    }

    /// Average brightness (0…1) of a strip of the note list's background near the bottom of the
    /// screen, below the demo notes.
    private func backgroundBrightness(_ app: XCUIApplication) -> Double {
        let image = app.screenshot().image
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let y = Int(Double(cgImage.height) * 0.80)
        var total = 0.0
        var count = 0
        for x in stride(from: cgImage.width / 10, to: cgImage.width * 9 / 10, by: 8) {
            let offset = y * cgImage.bytesPerRow + x * bytesPerPixel
            total += (Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])) / (3 * 255)
            count += 1
        }
        return total / Double(count)
    }
}
