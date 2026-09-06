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
        try checkJoinFailureKeepsFreshSetup()
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
        XCTAssertTrue(app.switches["eligible-nora"].exists)
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

    func testExistingAllChildrenChoreIncludesNewChildImmediately() throws {
        createFamily()
        addChild("Hanna")
        addChild("Alek")
        tap("setup-weekday-lists")
        tap("weekday-\(Calendar.current.component(.weekday, from: Date()))")
        tap("add-responsibility")
        fill("responsibility-title", with: "Feed dog")
        tap("save-responsibility")
        tap("add-responsibility")
        fill("responsibility-title", with: "Read book")
        tap("chore-requirement")
        tap("One child")
        app.switches["eligible-hanna"].switches.firstMatch.tap()
        tap("save-responsibility")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("finish-setup")
        tap("state-feed-dog-alek")
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-alek"], containing: "Done"))
        keepScreenshot("after-compact-two-children")
        tap("family-management")
        tap("family-add-child")
        fill("family-display-name", with: "New Child")
        tap("save-family-user")
        XCTAssertFalse(app.staticTexts["Joins lists tomorrow"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["state-feed-dog-new-child"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-alek"], containing: "Done"))
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-new-child"], containing: "Unmarked"))
        XCTAssertFalse(app.buttons["state-read-book-new-child"].exists)
        checkControls(["state-feed-dog-alek", "state-feed-dog-hanna", "state-feed-dog-new-child"])
        keepScreenshot("after-new-child-immediately-in-today")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .textClipped, .contrast, .hitRegion]) { issue in
            // The audit flags the decorative emoji's ink bounds. Its element screenshot
            // shows the full star inside the 52-point avatar, which is hidden from VoiceOver.
            guard issue.auditType == .textClipped, let element = issue.element else { return false }
            return element.label == "⭐️" && abs(element.frame.width - 52) < 0.01
                && abs(element.frame.height - 52) < 0.01
        }
        tap("switch-user")
        tap("user-card-new-child")
        reveal(app.buttons["state-feed-dog-new-child"])
        XCTAssertFalse(app.buttons["state-feed-dog-alek"].exists)
        XCTAssertFalse(app.staticTexts["Read book"].exists)
        tap("state-feed-dog-new-child")
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-new-child"], containing: "Done"))
        tap("state-feed-dog-new-child")
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-new-child"], containing: "Unmarked"))
        XCTAssertFalse(app.alerts["Remove this contribution?"].exists)
        app.buttons["state-feed-dog-new-child"].press(forDuration: 1)
        tap("Not Needed Today")
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-new-child"], containing: "Not Needed Today"))
        keepScreenshot("after-child-own-control-and-sibling-states")
        tap("state-feed-dog-new-child")
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-new-child"], containing: "Done"))
        relaunch()
        XCTAssertTrue(screen("child-home").waitForExistence(timeout: 8))
        reveal(app.buttons["state-feed-dog-new-child"])
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-new-child"], containing: "Done"))
        tap("switch-user")
        tap("user-card-test-parent")
        reveal(app.buttons["state-feed-dog-new-child"])
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-alek"], containing: "Done"))
        keepScreenshot("after-parent-completions-persist")
        tap("state-feed-dog-new-child")
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-new-child"], containing: "Unmarked"))
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-alek"], containing: "Done"))
        tap("family-management")
        tap("family-add-child")
        fill("family-display-name", with: "Alexandria Montgomery")
        tap("save-family-user")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        relaunch(largeType: true)
        reveal(app.buttons["state-feed-dog-alek"])
        keepScreenshot("after-largest-type-chore-title")
        checkControls(["state-feed-dog-alexandria-montgomery"])
        let longName = app.buttons["state-feed-dog-alexandria-montgomery"]
        let distance = min(300, max(0, longName.frame.midY - app.frame.midY))
        if distance > 0 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        keepScreenshot("after-largest-type-long-name")
        checkControls(["state-feed-dog-alek", "state-feed-dog-hanna", "state-feed-dog-new-child"])
        keepScreenshot("after-daily-list-largest-type")
        tap("state-feed-dog-new-child")
        XCTAssertTrue(waitForLabel(app.buttons["state-feed-dog-new-child"], containing: "Done"))
        keepScreenshot("after-largest-type-direct-toggle")
    }

    private func checkControls(_ identifiers: [String]) {
        for identifier in identifiers {
            let button = app.buttons[identifier]
            reveal(button)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44 - 0.01)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44 - 0.01)
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.width)
        }
    }

    private func checkJoinFailureKeepsFreshSetup() throws {
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
