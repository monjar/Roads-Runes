import CoreLocation
import XCTest

/// The main flows against the local API (`make api`), tapped the way a rider
/// taps: on the edge of a pill or in the gap of a row. A tap that only counts
/// on a label's glyphs is exactly what used to fail, so every tap here lands
/// away from the centre.
///
/// Each test signs in as a new developer subject and starts from Welcome.
/// On the simulator the position is set per test: Rotherhithe routes through
/// the London GraphHopper graph, Paris through Valhalla with places from OSM.
final class MainFlowsUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let rotherhithe = CLLocation(latitude: 51.4906, longitude: -0.0316)
    private static let paris = CLLocation(latitude: 48.8566, longitude: 2.3522)

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["RR_UI_TEST"] = "1"
    }

    // MARK: - Quests

    func testAcceptThenDetailsAndContinueFromTheCurrentQuestCard() throws {
        signInAsNewRider(at: Self.rotherhithe)
        tapTab("Quests")
        tapOffCentre(waitFor(app.buttons.matching(identifier: "questRow").firstMatch, 90), dx: 0.9)

        tapOffCentre(waitFor(app.buttons["quest.accept"]), dx: 0.12)
        XCTAssertTrue(app.buttons["quest.plan"].waitForExistence(timeout: 20), "Accept did not accept the quest")

        // Back on the list, the accepted quest is the current quest.
        tapOffCentre(app.buttons["quest.back"], dx: 0.5)
        tapOffCentre(waitFor(app.buttons["currentQuest.details"], 20), dx: 0.15)
        XCTAssertTrue(app.buttons["quest.plan"].waitForExistence(timeout: 20), "Details did not open the quest")
        tapOffCentre(app.buttons["quest.back"], dx: 0.5)

        tapOffCentre(waitFor(app.buttons["currentQuest.continue"], 20), dx: 0.08)
        XCTAssertTrue(app.buttons["planner.start"].waitForExistence(timeout: 90), "Continue did not open the quest route")
        tapOffCentre(app.buttons["planner.close"], dx: 0.5)
    }

    func testBeginQuestOpensItsFixedRouteAndRides() throws {
        signInAsNewRider(at: Self.rotherhithe)
        tapTab("Quests")
        tapOffCentre(waitFor(app.buttons.matching(identifier: "questRow").firstMatch, 90), dx: 0.05)

        tapOffCentre(waitFor(app.buttons["quest.begin"]), dx: 0.9)
        let start = waitFor(app.buttons["planner.start"], 90)
        XCTAssertTrue(app.staticTexts["Quest route"].exists, "The planner should open on the quest's own route")
        tapOffCentre(start, dx: 0.1)
        allowSystemAlertIfShown()  // background location for the ride

        tapOffCentre(waitFor(app.buttons["Pause ride"], 30), dx: 0.5)
        tapOffCentre(waitFor(app.buttons["End"]), dx: 0.15)
        waitFor(app.buttons["End & save"]).tap()
        let collect = app.buttons["Collect rewards"]
        XCTAssertTrue(collect.waitForExistence(timeout: 90), "No adventure summary after the ride")
        tapOffCentre(collect, dx: 0.1)
        // Back where the ride began: the quest, now in progress.
        XCTAssertTrue(app.buttons["quest.continue"].waitForExistence(timeout: 30), "The ride did not hand back to its quest")
    }

    func testCustomAdventurePlansThreeWaysToRide() throws {
        signInAsNewRider(at: Self.rotherhithe)
        tapTab("Quests")
        tapOffCentre(waitFor(app.buttons["customAdventure"], 30), dx: 0.7)
        XCTAssertTrue(app.buttons["planner.start"].waitForExistence(timeout: 90), "No route was planned")
        XCTAssertFalse(app.staticTexts["preview routing"].exists, "Fell back to synthetic routes")
        tapOffCentre(app.buttons["planner.close"], dx: 0.5)
    }

    /// "Richmond bike ride" used to plan a ride wherever the rider stood, because the
    /// parser only saw a place after "in"/"near". Drive it through the planner itself.
    func testAskingForARideInAPlacePlansItThere() throws {
        signInAsNewRider(at: Self.rotherhithe)
        tapTab("Quests")
        tapOffCentre(waitFor(app.buttons["customAdventure"], 30), dx: 0.7)

        let placeholder = "About 30 km, mostly quiet roads, easy gravel and a pub halfway."
        let field = app.textFields[placeholder].exists ? app.textFields[placeholder] : app.textViews[placeholder]
        waitFor(field, 30)
        field.tap()
        field.typeText("Richmond bike ride")
        // The request field is multi-line, so return adds a line rather than dismissing
        // the keyboard: scroll until the button is genuinely hittable before tapping it.
        let generate = app.buttons["Generate routes"]
        scrollTo(generate)
        tapOffCentre(generate, dx: 0.5)

        let understood = app.descendants(matching: .any).matching(identifier: "planner.understood").firstMatch
        XCTAssertTrue(understood.waitForExistence(timeout: 120), "The planner never said what it understood")
        XCTAssertTrue(understood.label.contains("Richmond"), "Understood '\(understood.label)' instead of Richmond")
        XCTAssertTrue(app.buttons["planner.start"].waitForExistence(timeout: 60), "No route came back")
        tapOffCentre(app.buttons["planner.close"], dx: 0.5)
    }

    // MARK: - World

    func testSearchAPlaceAndPlanARideThere() throws {
        signInAsNewRider(at: Self.rotherhithe)
        tapOffCentre(app.buttons["Search places"], dx: 0.6)
        let field = waitFor(app.textFields["Search places"])
        field.typeText("cafe\n")
        tapOffCentre(waitFor(app.buttons.matching(identifier: "placeRow").firstMatch, 30), dx: 0.62)
        tapOffCentre(waitFor(app.buttons["Ride here"]), dx: 0.1)
        XCTAssertTrue(app.buttons["planner.start"].waitForExistence(timeout: 90), "No route to the place")
        tapOffCentre(app.buttons["planner.close"], dx: 0.5)
    }

    // MARK: - Outside London

    func testQuestsAndRoutesOutsideTheLondonGraph() throws {
        signInAsNewRider(at: Self.paris)
        tapTab("Quests")
        XCTAssertTrue(app.buttons.matching(identifier: "questRow").firstMatch.waitForExistence(timeout: 120), "No quests in Paris")
        tapOffCentre(app.buttons["customAdventure"], dx: 0.7)
        XCTAssertTrue(app.buttons["planner.start"].waitForExistence(timeout: 120), "No route in Paris")
        XCTAssertFalse(app.staticTexts["preview routing"].exists, "Paris fell back to synthetic routes")
        tapOffCentre(app.buttons["planner.close"], dx: 0.5)
    }

    // MARK: - Journal and character

    func testOnboardingBikeShowsUpOnTheCharacterTab() throws {
        signInAsNewRider(at: Self.rotherhithe)
        tapTab("Journal")
        XCTAssertTrue(app.staticTexts["Journal"].waitForExistence(timeout: 20))
        tapTab("Character")
        let bike = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI test gravel")).firstMatch
        scrollTo(bike)
        tapOffCentre(bike, dx: 0.6)
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10), "The bike row did not open its editor")
    }

    // MARK: - Helpers

    /// Welcome → developer sign-in → character → bike → location, as a new rider.
    private func signInAsNewRider(at location: CLLocation) {
        #if targetEnvironment(simulator)
        XCUIDevice.shared.location = XCUILocation(location: location)
        #endif
        app.launch()
        replaceText(in: waitFor(app.textFields["Developer subject"]), with: "ui-\(UUID().uuidString.prefix(8).lowercased())")
        tapOffCentre(app.buttons["Developer sign in"], dx: 0.5)

        replaceText(in: waitFor(app.textFields["Your name"], 30), with: "Wren")
        tapOffCentre(waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ride as")).firstMatch), dx: 0.1)

        replaceText(in: waitFor(app.textFields["Bike name"], 30), with: "UI test gravel")
        app.buttons["Gravel"].tap()
        tapOffCentre(app.buttons["Continue"], dx: 0.1)

        tapOffCentre(waitFor(app.buttons["Allow location"], 20), dx: 0.1)
        allowSystemAlertIfShown()
        waitFor(app.buttons["Search places"], 30)
    }

    /// Scrolls the screen until the element is there and on screen; bikes sit
    /// far down the character tab, below abilities and the cycling profile.
    private func scrollTo(_ element: XCUIElement, swipes: Int = 6, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) never came into view", file: file, line: line)
    }

    private func tapTab(_ title: String) {
        tapOffCentre(waitFor(app.buttons[title]), dx: 0.8)
    }

    /// Taps inside the element but away from its centre, where a label's text is
    /// not, once it has stopped moving (keyboard and sheet animations).
    private func tapOffCentre(_ element: XCUIElement, dx: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(element) never appeared", file: file, line: line)
        let deadline = Date().addingTimeInterval(10)
        while !element.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
    }

    /// Replaces a field's text and presses return, so the keyboard is gone and
    /// the buttons pinned above it have settled before the next tap.
    private func replaceText(in field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let value = field.value as? String ?? ""
        let existing = value == field.placeholderValue ? "" : value  // an empty field reports its placeholder
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + text + "\n")
    }

    @discardableResult
    private func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Timed out waiting for \(element)", file: file, line: line)
        return element
    }

    /// Location prompts are SpringBoard alerts, outside the app's hierarchy.
    private func allowSystemAlertIfShown() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow While Using App", "Change to Always Allow", "Allow"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                return
            }
        }
    }
}
