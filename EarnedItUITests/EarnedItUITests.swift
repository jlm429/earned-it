import XCTest

final class EarnedItUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-test-store", "--ui-test-reset"]
        if name.contains("LargeType") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 8))
    }

    func testCreateSharedChoreIndependentCompletionsParentVisibilityAndRelaunch() throws {
        keepScreenshot("fresh-create-or-join")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
        createFamily()
        addChild("Hanna")
        addChild("Alek")
        tap("setup-weekday-lists")
        let weekday = Calendar.current.component(.weekday, from: Date())
        tap("weekday-\(weekday)")
        tap("add-responsibility")
        XCTAssertFalse(app.buttons["save-responsibility"].isEnabled)
        fill("responsibility-title", with: "Water plants")
        XCTAssertTrue(app.buttons["chore-requirement"].exists)
        tap("save-responsibility")
        XCTAssertTrue(app.staticTexts["Water plants"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("finish-setup")
        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Water plants"].exists)
        keepScreenshot("parent-shared-daily-list")
        tap("switch-user")
        tap("user-card-hanna")
        XCTAssertTrue(screen("child-home").waitForExistence(timeout: 5))
        tap("state-water-plants-hanna")
        tap("Done")
        XCTAssertTrue(waitForLabel(app.buttons["state-water-plants-hanna"], containing: "Done"))
        keepScreenshot("hanna-completed-alek-still-needed")
        relaunch()
        XCTAssertTrue(screen("child-home").waitForExistence(timeout: 8))
        reveal(app.buttons["state-water-plants-hanna"])
        XCTAssertTrue(waitForLabel(app.buttons["state-water-plants-hanna"], containing: "Done"))
        tap("switch-user")
        tap("user-card-test-parent")
        reveal(app.buttons["state-water-plants-hanna"])
        XCTAssertTrue(waitForLabel(app.buttons["state-water-plants-hanna"], containing: "Done"))
        XCTAssertTrue(waitForLabel(app.buttons["state-water-plants-alek"], containing: "Unmarked"))
        keepScreenshot("parent-who-did-what-without-opening-child")
        tap("switch-user")
        tap("user-card-alek")
        tap("state-water-plants-alek")
        tap("Done")
        XCTAssertTrue(app.staticTexts["Complete"].exists)
        tap("switch-user")
        tap("user-card-hanna")
        tap("state-water-plants-hanna")
        tap("Unmarked")
        tap("Cancel")
        XCTAssertTrue(waitForLabel(app.buttons["state-water-plants-hanna"], containing: "Done"))
        tap("state-water-plants-hanna")
        tap("Unmarked")
        tap("Remove Contribution")
        XCTAssertTrue(waitForLabel(app.buttons["state-water-plants-hanna"], containing: "Unmarked"))
        tap("switch-user")
        tap("user-card-test-parent")
        reveal(app.buttons["state-water-plants-alek"])
        XCTAssertTrue(waitForLabel(app.buttons["state-water-plants-alek"], containing: "Done"))
        XCTAssertTrue(waitForLabel(app.buttons["state-water-plants-hanna"], containing: "Unmarked"))
        keepScreenshot("removal-preserves-other-child")
        tap("parent-child-hanna")
        XCTAssertTrue(screen("parent-child-detail").waitForExistence(timeout: 5))
        keepScreenshot("weekly-progress-and-excused-day")
    }

    func testPartialSetupDuplicatePreventionAndConfirmedResetAtLargeType() throws {
        createFamily()
        relaunch(largeType: true)
        XCTAssertTrue(app.navigationBars["Family Setup"].waitForExistence(timeout: 8))
        XCTAssertTrue(screen("setup-user-test-parent").exists)
        tap("setup-add-child")
        fill("family-display-name", with: "Discarded")
        tap("Cancel")
        reveal(app.buttons["finish-setup"])
        XCTAssertFalse(app.buttons["finish-setup"].isEnabled)
        addChild("Hanna")
        tap("setup-add-child")
        fill("family-display-name", with: " hanna ")
        tap("save-family-user")
        XCTAssertTrue(app.alerts["Unable to Save"].waitForExistence(timeout: 5))
        tap("OK")
        tap("Cancel")
        keepScreenshot("persisted-setup-largest-text")
        tap("finish-setup")
        XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 5))
        keepScreenshot("empty-parent-largest-text")
        tap("family-management")
        tap("household-settings")
        tap("clear-all-data")
        tap("Cancel")
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        tap("clear-all-data")
        tap("Remove Local Data")
        XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 5))
        relaunch(largeType: true)
        XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 8))
        reveal(app.buttons["create-family"])
        XCTAssertTrue(app.buttons["create-family"].exists)
        keepScreenshot("fresh-after-confirmed-local-reset")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
    }

    func testJoinFailureKeepsFreshSetupAndDoesNotCreateFakeFamily() throws {
        tap("join-family")
        keepScreenshot("native-join-existing-family")
        tap("find-families")
        XCTAssertTrue(app.alerts["Unable to Connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS 'iCloud sharing is unavailable'")).firstMatch.exists)
        keepScreenshot("unsigned-simulator-sharing-dependency")
        tap("OK")
        tap("Cancel")
        XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 5))
        relaunch()
        XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 8))
        XCTAssertFalse(screen("parent-dashboard").exists)
        XCTAssertFalse(screen("profile-selection").exists)
    }

    func testChoreAssignmentDatesAfterMembershipChanges() throws {
        createFamily()
        addChild("Hanna")
        addChild("Alek")
        tap("finish-setup")
        tap("family-management")
        tap("family-add-child")
        fill("family-display-name", with: "Nora")
        tap("save-family-user")
        tap("Manage Alek")
        tap("Archive Member")
        tap("Archive from Tomorrow")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("weekday-lists-link")
        tap("weekday-2")
        tap("add-responsibility")
        fill("responsibility-title", with: "New assignment")
        tap("chore-requirement")
        tap("One child")
        let alek = app.switches["eligible-alek"]
        reveal(alek)
        XCTAssertFalse(app.switches["eligible-nora"].exists)
        alek.switches.firstMatch.tap()
        XCTAssertEqual(alek.value as? String, "1")
        keepScreenshot("r12-new-chore-today-eligibility")
        tap("save-responsibility")
        XCTAssertTrue(app.staticTexts["New assignment"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Unable to Save"].exists)
        tap("Edit")
        let nora = app.switches["eligible-nora"]
        reveal(nora)
        XCTAssertFalse(app.switches["eligible-alek"].exists)
        nora.switches.firstMatch.tap()
        XCTAssertEqual(nora.value as? String, "1")
        keepScreenshot("r12-edit-chore-tomorrow-eligibility")
        tap("save-responsibility")
        XCTAssertTrue(app.staticTexts["Starts tomorrow"].waitForExistence(timeout: 5))
        relaunch()
        tap("weekday-lists-link")
        tap("weekday-2")
        tap("Edit")
        reveal(app.switches["eligible-nora"])
        XCTAssertEqual(app.switches["eligible-nora"].value as? String, "1")
        XCTAssertFalse(app.switches["eligible-alek"].exists)
        keepScreenshot("r12-reassignment-persists-after-relaunch")
        tap("Cancel")
    }

    private func createFamily() {
        tap("create-family")
        fill("family-name", with: "Test Family")
        fill("parent-name", with: "Test Parent")
        tap("save-family")
        XCTAssertTrue(app.navigationBars["Family Setup"].waitForExistence(timeout: 5))
    }

    private func addChild(_ name: String) {
        tap("setup-add-child")
        fill("family-display-name", with: name)
        tap("save-family-user")
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.textFields["family-display-name"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    private func fill(_ identifier: String, with text: String) {
        let field = app.textFields[identifier]
        reveal(field)
        field.tap()
        field.typeText(text)
        if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
    }

    private func relaunch(largeType: Bool = false) {
        app.terminate()
        app.launchArguments = ["--ui-test-store"]
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
    }

    private func tap(_ identifier: String) {
        let element = app.buttons[identifier]
        reveal(element)
        element.tap()
    }

    private func reveal(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 2)
        for _ in 0..<8 where !element.exists || !element.isHittable { app.swipeUp() }
        if !element.exists || !element.isHittable {
            for _ in 0..<10 where !element.exists || !element.isHittable { app.swipeDown() }
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }

    private func screen(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier] }
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
