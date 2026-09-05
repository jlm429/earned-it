import XCTest

final class EarnedItUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-test-store", "--ui-test-reset"]
        if name.contains("testSkippedEmpty") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 8))
    }

    func testCompletedSetupChildCompletionParentReviewAndRelaunch() throws {
        keepScreenshot("welcome")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        tap("setup-continue")
        addPerson(button: "setup-add-parent", name: "Test Parent")
        tap("setup-continue")
        addPerson(button: "setup-add-child", name: "Test Child")
        addPerson(button: "setup-add-child", name: "Second Child")
        tap("setup-continue")
        tap("setup-add-chore")
        XCTAssertFalse(app.buttons["save-responsibility"].isEnabled)
        fill("responsibility-title", with: "Water plants")
        tap("save-responsibility")
        XCTAssertTrue(app.staticTexts["Water plants"].waitForExistence(timeout: 5))
        tap("setup-continue")
        keepScreenshot("workflow-guide")
        tap("setup-continue")
        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 5))
        keepScreenshot("completed-parent-dashboard")
        relaunch()
        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["setup-continue"].exists)
        tap("switch-user")
        tap("user-card-test-child")
        XCTAssertTrue(screen("child-home").waitForExistence(timeout: 5))
        tap("state-control-water-plants")
        tap("Done")
        XCTAssertTrue(waitForLabel(screen("state-control-water-plants"), containing: "Done"))
        keepScreenshot("child-completion")
        relaunch()
        XCTAssertTrue(screen("child-home").waitForExistence(timeout: 8))
        reveal(screen("state-control-water-plants"))
        XCTAssertTrue(waitForLabel(screen("state-control-water-plants"), containing: "Done"))
        tap("switch-user")
        tap("user-card-test-parent")
        tap("parent-child-test-child")
        XCTAssertTrue(screen("parent-child-detail").waitForExistence(timeout: 5))
        tap("state-control-water-plants")
        tap("Not Needed Today")
        XCTAssertTrue(waitForLabel(screen("state-control-water-plants"), containing: "Not Needed Today"))
        reveal(screen("view-weekly-summary"), upward: false)
        tap("view-weekly-summary")
        XCTAssertTrue(screen("weekly-summary").waitForExistence(timeout: 5))
        keepScreenshot("parent-weekly-review")
    }

    func testSkippedEmptyStoreNormalNavigationAndConfirmedResetAtLargeType() throws {
        keepScreenshot("welcome-largest-dynamic-type")
        tap("setup-skip")
        tap("Cancel")
        XCTAssertTrue(app.buttons["setup-continue"].exists)
        tap("setup-skip")
        tap("Skip Setup")
        XCTAssertTrue(app.buttons["add-parent"].waitForExistence(timeout: 5))
        XCTAssertEqual(userCardCount, 0)
        relaunch(largeType: true)
        XCTAssertTrue(app.buttons["add-parent"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["setup-continue"].exists)
        keepScreenshot("empty-user-picker-largest-dynamic-type")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        addPerson(button: "add-parent", name: "Test Parent")
        tap("user-card-test-parent")
        XCTAssertTrue(app.buttons["dashboard-add-child"].waitForExistence(timeout: 5))
        keepScreenshot("empty-parent-dashboard-largest-dynamic-type")
        addPerson(button: "dashboard-add-child", name: "Test Child")
        tap("parent-child-test-child")
        tap("empty-add-chore")
        tap("cancel-responsibility")
        reveal(screen("view-weekly-summary"), upward: false)
        tap("view-weekly-summary")
        XCTAssertTrue(screen("weekly-summary").waitForExistence(timeout: 5))
        keepScreenshot("empty-weekly-summary-largest-dynamic-type")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("switch-user")
        tap("user-card-test-child")
        XCTAssertTrue(screen("child-home").waitForExistence(timeout: 5))
        tap("empty-add-chore")
        tap("cancel-responsibility")
        tap("switch-user")
        tap("household-settings")
        tap("clear-all-data")
        tap("Cancel")
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        tap("clear-all-data")
        tap("Delete All Data")
        XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 5))
        relaunch()
        XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 8))
        tap("setup-skip")
        tap("Skip Setup")
        XCTAssertTrue(app.buttons["add-parent"].waitForExistence(timeout: 5))
        XCTAssertEqual(userCardCount, 0)
    }

    func testPartialSetupBackCancelDuplicatePreventionSkipResumeAndRestart() {
        tap("setup-continue")
        tap("setup-add-parent")
        XCTAssertFalse(app.buttons["save-family-user"].isEnabled)
        fill("family-display-name", with: "Discarded Parent")
        tap("Cancel")
        XCTAssertFalse(app.buttons["setup-continue"].isEnabled)
        addPerson(button: "setup-add-parent", name: "Test Parent")
        tap("setup-continue")
        relaunch()
        XCTAssertTrue(app.navigationBars["Add Children"].waitForExistence(timeout: 8))
        tap("setup-back")
        tap("setup-add-parent")
        fill("family-display-name", with: " test parent ")
        tap("save-family-user")
        XCTAssertTrue(app.alerts["Unable to Save"].waitForExistence(timeout: 5))
        tap("OK")
        tap("Cancel")
        tap("setup-continue")
        tap("setup-add-child")
        fill("family-display-name", with: "Discarded Child")
        tap("Cancel")
        XCTAssertFalse(app.buttons["setup-continue"].isEnabled)
        tap("setup-skip")
        tap("Skip Setup")
        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 5))
        relaunch()
        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 8))
        tap("switch-user")
        XCTAssertEqual(userCardCount, 1)
        tap("household-settings")
        tap("resume-setup")
        XCTAssertTrue(app.navigationBars["Add Children"].waitForExistence(timeout: 5))
        addPerson(button: "setup-add-child", name: "Test Child")
        tap("setup-continue")
        tap("setup-continue")
        tap("setup-continue")
        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 5))
        tap("switch-user")
        tap("household-settings")
        tap("restart-setup")
        XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 5))
        tap("setup-continue")
        XCTAssertTrue(screen("setup-user-test-parent").exists)
        tap("setup-continue")
        XCTAssertTrue(screen("setup-user-test-child").exists)
        tap("setup-continue")
        tap("setup-continue")
        tap("setup-continue")
        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 5))
        tap("switch-user")
        XCTAssertEqual(userCardCount, 2)
        keepScreenshot("restart-preserves-family-without-duplicates")
    }

    private var userCardCount: Int {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'user-card-'")).count
    }

    private func addPerson(button: String, name: String) {
        tap(button)
        fill("family-display-name", with: name)
        tap("save-family-user")
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.textFields["family-display-name"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    private func fill(_ identifier: String, with text: String) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        if app.keyboards.buttons["Return"].exists {
            app.keyboards.buttons["Return"].tap()
        }
    }

    private func relaunch(largeType: Bool = false) {
        app.terminate()
        app.launchArguments = ["--ui-test-store"]
        if largeType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
    }

    private func tap(_ identifier: String) {
        let element = app.buttons[identifier]
        reveal(element)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, upward: Bool = true) {
        _ = element.waitForExistence(timeout: 2)
        for _ in 0..<10 where !element.exists || !element.isHittable {
            if upward { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }

    private func screen(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
