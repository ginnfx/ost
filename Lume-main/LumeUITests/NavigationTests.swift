import XCTest

final class NavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    func testTabBarExists() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    func testNavigationToMovies() {
        let moviesTab = app.tabBars.buttons["Movies"]
        XCTAssertTrue(moviesTab.waitForExistence(timeout: 5))
        moviesTab.tap()
        XCTAssertTrue(app.navigationBars["Movies"].waitForExistence(timeout: 3))
    }

    func testNavigationToSeries() {
        let seriesTab = app.tabBars.buttons["Series"]
        XCTAssertTrue(seriesTab.waitForExistence(timeout: 5))
        seriesTab.tap()
        XCTAssertTrue(app.navigationBars["Series"].waitForExistence(timeout: 3))
    }

    func testNavigationToLiveTV() {
        let liveTab = app.tabBars.buttons["Live TV"]
        XCTAssertTrue(liveTab.waitForExistence(timeout: 5))
        liveTab.tap()
        XCTAssertTrue(app.navigationBars["Live TV"].waitForExistence(timeout: 3))
    }

    func testNavigationToHome() {
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5))
        homeTab.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
    }

    func testAllTabsAreAccessible() {
        let tabs = app.tabBars.buttons
        XCTAssertTrue(tabs["Home"].exists)
        XCTAssertTrue(tabs["Movies"].exists)
        XCTAssertTrue(tabs["Series"].exists)
        XCTAssertTrue(tabs["Live TV"].exists)
    }
}
