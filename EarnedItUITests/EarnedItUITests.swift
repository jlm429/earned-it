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
        if name.contains("WeeklyAllowance") {
            app.launchArguments += ["--ui-test-weekly-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        }
        app.launch()
        if name.contains("WeeklyAllowance") {
            XCTAssertTrue(screen("parent-dashboard").waitForExistence(timeout: 8))
        } else {
            XCTAssertTrue(app.navigationBars["Welcome"].waitForExistence(timeout: 8))
        }
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
            // Captured audit attachments show the full decorative star, not clipped text.
            // Its shading is not a text contrast signal. AvatarView hides it from VoiceOver;
            // the adjacent member name and status carry meaning and remain fully audited.
            guard issue.auditType == .textClipped || issue.auditType == .contrast,
                  let element = issue.element, element.label == "⭐️",
                  abs(element.frame.width - 52) < 0.01,
                  abs(element.frame.height - 52) < 0.01 else { return false }
            let progress = self.app.buttons["parent-child-alek"]
            return progress.exists && progress.frame.contains(element.frame)
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

    func testAlternatingChoreShowsOnlyTheCurrentChildTurn() throws {
        createFamily()
        addChild("Hanna")
        addChild("Alek")
        addChild("Nora")
        tap("setup-weekday-lists")
        tap("weekday-\(Calendar.current.component(.weekday, from: Date()))")
        tap("add-responsibility")
        fill("responsibility-title", with: "Set the table")
        tap("chore-requirement")
        tap("Alternate / take turns")
        app.switches["eligible-hanna"].switches.firstMatch.tap()
        app.switches["eligible-alek"].switches.firstMatch.tap()
        app.switches["eligible-nora"].switches.firstMatch.tap()
        XCTAssertEqual(app.staticTexts["alternating-turn-order"].label,
                       "Turn order: Alek, Hanna, Nora. It advances with each scheduled date, even when a turn is not completed.")
        keepScreenshot("alternating-three-child-turn-order")
        tap("save-responsibility")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("finish-setup")

        XCTAssertTrue(app.staticTexts["full-status-set-the-table"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["full-status-set-the-table"].label.contains("Alek’s turn"))
        XCTAssertTrue(app.buttons["state-set-the-table-alek"].exists)
        XCTAssertFalse(app.buttons["state-set-the-table-hanna"].exists)
        XCTAssertFalse(app.buttons["state-set-the-table-nora"].exists)
        keepScreenshot("alternating-parent-current-owner")

        tap("switch-user")
        tap("user-card-alek")
        XCTAssertTrue(app.staticTexts["full-status-set-the-table"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["full-status-set-the-table"].label.contains("Your turn"))
        XCTAssertTrue(app.buttons["state-set-the-table-alek"].exists)
        keepScreenshot("alternating-current-child-your-turn")

        tap("switch-user")
        tap("user-card-hanna")
        XCTAssertFalse(app.staticTexts["Set the table"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["state-set-the-table-alek"].exists)
        keepScreenshot("alternating-other-child-hidden")
    }

    func testWeeklyAllowanceHistoryGraceCelebrationAndRollover() throws {
        tap("parent-child-hanna")
        tap("edit-allowance")
        fill("allowance-amount", with: "12.345")
        tap("save-allowance")
        XCTAssertTrue(app.alerts["Unable to Save"].waitForExistence(timeout: 5))
        tap("OK")
        replaceAmount("12.34")
        keepScreenshot("weekly-edit-fractional-allowance")
        tap("save-allowance")
        XCTAssertTrue(app.staticTexts["$12.34"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("parent-child-alek")
        tap("edit-allowance")
        fill("allowance-amount", with: "4.50")
        tap("save-allowance")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("switch-user")
        tap("user-card-hanna")
        keepScreenshot("weekly-current-week-start")
        checkControls(["view-weekly-summary"])
        XCTAssertFalse(screen("week-celebration").exists)
        keepScreenshot("weekly-current-future-not-missed")
        advanceWeeklyClock(to: "Sunday")
        XCTAssertFalse(screen("week-celebration").exists)
        advanceWeeklyClock(to: "Next Monday")
        reveal(screen("parent-check-in"))
        keepScreenshot("weekly-finished-gentle-parent-reminder")
        tap("yesterday-items")
        tap("state-pack-school-bag-hanna")
        XCTAssertTrue(waitForLabel(app.buttons["state-pack-school-bag-hanna"], containing: "Done"))
        keepScreenshot("weekly-sunday-completed-during-monday-grace")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(screen("week-celebration"))
        XCTAssertTrue(app.staticTexts["Way to go!"].exists)
        keepScreenshot("weekly-earned-it-way-to-go")
        relaunchWeekly(date: "2026-09-14T16:00:00Z")
        XCTAssertFalse(screen("week-celebration").exists)
        reveal(screen("earned-it-badge"))
        keepScreenshot("weekly-badge-persists-without-replay")
        advanceWeeklyClock(to: "Next Tuesday")
        tap("switch-user")
        tap("user-card-alek")
        tap("view-weekly-summary")
        XCTAssertTrue(app.navigationBars["Weekly History"].waitForExistence(timeout: 5))
        tap("weekly-item-2026-09-13-pack-school-bag")
        XCTAssertTrue(app.navigationBars["Day’s Items"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["state-pack-school-bag-alek"].exists)
        XCTAssertTrue(screen("completion-cutoff").exists)
        XCTAssertFalse(app.staticTexts["Tap a name to mark done or undo. Touch and hold for other states."].exists)
        keepScreenshot("weekly-child-locked-after-grace")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("switch-user")
        tap("user-card-test-parent")
        tap("parent-child-alek")
        tap("previous-week")
        keepScreenshot("weekly-parent-missing-items-and-dates")
        tap("weekly-item-2026-09-13-pack-school-bag")
        tap("state-pack-school-bag-alek")
        XCTAssertTrue(waitForLabel(app.buttons["state-pack-school-bag-alek"], containing: "Done"))
        keepScreenshot("weekly-parent-corrects-locked-sunday")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("weekly-item-2026-09-07-water-plants")
        tap("state-water-plants-alek")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(screen("earned-it-badge"))
        keepScreenshot("weekly-corrected-parent-earned-outcome")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("parent-child-hanna")
        tap("edit-allowance")
        replaceAmount("20.05")
        tap("save-allowance")
        tap("previous-week")
        XCTAssertTrue(app.staticTexts["$12.34 weekly allowance"].waitForExistence(timeout: 5))
        keepScreenshot("weekly-finished-amount-preserved-after-edit")
        relaunchWeekly(date: "2026-09-15T16:00:00Z", largeType: true)
        tap("parent-child-hanna")
        reveal(app.staticTexts["$20.05 weekly allowance"])
        keepScreenshot("weekly-current-largest-type")
        try app.performAccessibilityAudit(for: .sufficientElementDescription)
    }

    private func advanceWeeklyClock(to title: String) {
        tap("test-clock")
        // A presented native menu is outside the scrolling content bounds.
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        XCTAssertTrue(option.isHittable)
        option.tap()
    }

    private func replaceAmount(_ text: String) {
        let field = app.textFields["allowance-amount"]
        reveal(field)
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    private func relaunchWeekly(date: String, largeType: Bool = false, hideClock: Bool = false) {
        app.terminate()
        app.launchArguments = ["--ui-test-store", "--ui-test-weekly-fixture", "--ui-test-date=\(date)",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if hideClock { app.launchArguments += ["--ui-test-hide-clock"] }
        if largeType { app.launchArguments += ["--ui-test-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(screen("child-home").waitForExistence(timeout: 8) || screen("parent-dashboard").exists)
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
        if identifier == "test-clock" || app.navigationBars.buttons[identifier].exists {
            XCTAssertTrue(element.waitForExistence(timeout: 5))
        } else {
            reveal(element)
        }
        element.tap()
    }

    private func reveal(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 2)
        // SwiftUI can report a link as hittable while it is covered by an inset or bar.
        // Scroll its center into the content area before synthesizing the tap.
        func safelyVisible() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            let bottom = app.frame.maxY - 36
            return element.frame.midY > top && element.frame.midY < bottom
        }
        let scroll: XCUIElement
        if app.scrollViews.firstMatch.exists {
            scroll = app.scrollViews.firstMatch
        } else if app.collectionViews.firstMatch.exists {
            scroll = app.collectionViews.firstMatch
        } else if app.tables.firstMatch.exists {
            scroll = app.tables.firstMatch
        } else {
            scroll = app
        }
        // Forms virtualize distant cells. Search enough content at accessibility text sizes
        // before reversing direction; once mounted, the element's frame directs each drag.
        for index in 0..<80 {
            if safelyVisible() { break }
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            let bottom = app.frame.maxY - 36
            let center = (top + bottom) / 2
            let targetY = element.exists && !element.frame.isEmpty
                ? element.frame.midY : (index < 40 ? bottom + 160 : top - 160)
            let distance = min(160, max(-160, targetY - center))
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0))
                .withOffset(CGVector(dx: 0, dy: center - scroll.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(safelyVisible(), "Target \(element.identifier), frame \(element.frame), navigation bar \(app.navigationBars.firstMatch.frame)")
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
