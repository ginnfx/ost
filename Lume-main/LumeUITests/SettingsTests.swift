import XCTest

final class SettingsTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    private func openSettings() {
        app.buttons["gear"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
    }

    func testSettingsAccessibleFromToolbar() {
        openSettings()
    }

    func testPlaylistsSectionShowsPlaylist() {
        openSettings()
        let playlistName = app.staticTexts["Test Playlist"]
        XCTAssertTrue(playlistName.waitForExistence(timeout: 3))
    }

    func testPlayerEnginePickerExists() {
        openSettings()
        let engineLabel = app.staticTexts["Engine"]
        XCTAssertTrue(engineLabel.waitForExistence(timeout: 3))
    }

    func testAddPlaylistButtonExists() {
        openSettings()
        let addButton = app.buttons["Add Playlist"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
    }

    func testPlaylistDetailNavigation() {
        openSettings()
        let playlistName = app.staticTexts["Test Playlist"]
        XCTAssertTrue(playlistName.waitForExistence(timeout: 3))
        playlistName.tap()
        XCTAssertTrue(app.navigationBars["Test Playlist"].waitForExistence(timeout: 3))
        let nameLabel = app.staticTexts["Name"]
        XCTAssertTrue(nameLabel.waitForExistence(timeout: 3))
    }
}
