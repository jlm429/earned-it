import XCTest

final class EarnedItUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--reset-sample-data"]
        app.launch()
        XCTAssertTrue(app.buttons["user-card-parent"].waitForExistence(timeout: 8))
        keepScreenshot(named: "user-selection")
    }

    func testChildMarksDoneAndNotNeededToday() {
        app.buttons["user-card-child-one"].tap()
        XCTAssertTrue(screen("child-home").waitForExistence(timeout: 5))

        let feedPet = screen("state-control-feed-pet")
        reveal(feedPet, swiping: .up)
        feedPet.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(waitForLabel(feedPet, containing: "Done"))

        let practiceReading = screen("state-control-practice-reading")
        reveal(practiceReading, swiping: .up)
        practiceReading.tap()
        app.buttons["Not Needed Today"].tap()
        XCTAssertTrue(waitForLabel(practiceReading, containing: "Not Needed Today"))
        keepScreenshot(named: "child-today")
    }

    func testParentInspectsChildAndResetsItem() {
        app.buttons["user-card-parent"].tap()
        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 5))
        keepScreenshot(named: "parent-dashboard")

        app.descendants(matching: .any)["parent-child-child-one"].tap()
        XCTAssertTrue(screen("parent-child-detail").waitForExistence(timeout: 5))

        let makeBed = screen("state-control-make-bed")
        reveal(makeBed, swiping: .up)
        makeBed.tap()
        app.buttons["Unmarked"].tap()
        XCTAssertTrue(waitForLabel(makeBed, containing: "Unmarked"))
        keepScreenshot(named: "parent-child-detail")

        let weeklySummary = app.descendants(matching: .any)["view-weekly-summary"]
        reveal(weeklySummary, swiping: .down)
        weeklySummary.tap()
        XCTAssertTrue(screen("weekly-summary").waitForExistence(timeout: 5))
        keepScreenshot(named: "weekly-summary")
    }

    func testParentAddsResponsibilityVisibleToChild() {
        app.buttons["user-card-parent"].tap()
        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 5))
        app.buttons["add-responsibility"].tap()

        let titleField = app.textFields["responsibility-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("Water plants")
        if app.keyboards.buttons["Return"].exists {
            app.keyboards.buttons["Return"].tap()
        }
        keepScreenshot(named: "responsibility-creation")
        app.buttons["save-responsibility"].tap()

        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 5))
        app.buttons["switch-user"].tap()
        XCTAssertTrue(app.buttons["user-card-child-one"].waitForExistence(timeout: 5))
        app.buttons["user-card-child-one"].tap()

        let newItem = app.descendants(matching: .any)["responsibility-row-water-plants"]
        reveal(newItem, swiping: .up)
        XCTAssertTrue(newItem.exists)
        keepScreenshot(named: "child-today-with-new-responsibility")
    }

    private enum SwipeDirection {
        case up
        case down
    }

    private func reveal(_ element: XCUIElement, swiping direction: SwipeDirection) {
        for _ in 0..<8 where !element.isHittable {
            switch direction {
            case .up: app.swipeUp()
            case .down: app.swipeDown()
            }
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2))
        XCTAssertTrue(element.isHittable)
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }

    private func screen(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
