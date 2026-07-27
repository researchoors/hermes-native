#if os(iOS)
import XCTest

// iOS smoke tests: tab nav, session lifecycle, input bar correctness.
// Runs against a live gateway — XCTSkip when HERMES_NATIVE_GATEWAY_URL is absent.
final class HermesNativeIOSSmokeTests: XCTestCase {

    // MARK: - Shared helpers

    private var gatewayURL: String {
        ProcessInfo.processInfo.environment["HERMES_NATIVE_GATEWAY_URL"] ?? ""
    }

    private var apiKey: String? {
        ProcessInfo.processInfo.environment["HERMES_NATIVE_API_KEY"]
            ?? ProcessInfo.processInfo.environment["API_SERVER_KEY"]
    }

    @MainActor
    private func launchApp() throws -> XCUIApplication {
        guard !gatewayURL.isEmpty else {
            throw XCTSkip("HERMES_NATIVE_GATEWAY_URL not set — skipping live gateway test")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        var env = ["HERMES_NATIVE_GATEWAY_URL": gatewayURL]
        if let key = apiKey, !key.isEmpty { env["HERMES_NATIVE_API_KEY"] = key }
        app.launchEnvironment = env
        app.launch()
        return app
    }

    @MainActor
    private func connectAndReachSessions(_ app: XCUIApplication) -> Bool {
        let marker = app.staticTexts["Sessions"]
        if !marker.waitForExistence(timeout: 4) {
            let connect = app.buttons["connectButton"]
            if connect.waitForExistence(timeout: 10) { connect.tap() }
        }
        return marker.waitForExistence(timeout: 25)
    }

    @MainActor
    private func openNewSession(_ app: XCUIApplication) {
        let start = app.buttons["startNewChatButton"].firstMatch
        let new = app.buttons["newSessionButton"].firstMatch
        if start.waitForExistence(timeout: 2) { start.tap() }
        else { _ = new.waitForExistence(timeout: 10); new.tap() }
    }

    @MainActor
    private func chatInput(_ app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        let tv = app.textViews["chatInput"]
        if tv.waitForExistence(timeout: timeout / 2) { return tv }
        let tf = app.textFields["chatInput"]
        _ = tf.waitForExistence(timeout: timeout / 2)
        return tf
    }

    @MainActor
    private func sendMessage(_ app: XCUIApplication, text: String) {
        let input = chatInput(app)
        XCTAssertTrue(input.exists, "chatInput must exist before sending")
        input.tap()
        input.typeText(text)
        let send = app.buttons["sendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    @MainActor
    private func waitForStreamingToFinish(_ app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
        let stop = app.buttons["stopButton"].firstMatch
        if stop.waitForExistence(timeout: 8) {
            return stop.waitForNonExistence(timeout: timeout)
        }
        return true
    }

    @MainActor
    private func assertInputBarUsable(_ app: XCUIApplication, context: String) {
        let input = chatInput(app, timeout: 5)
        XCTAssertTrue(input.exists, "[\(context)] chatInput should exist")
        XCTAssertTrue(input.isEnabled, "[\(context)] chatInput should be enabled")
        input.tap()
        input.typeText(" ")
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        let send = app.buttons["sendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "[\(context)] sendButton should exist")
        XCTAssertTrue(send.isHittable, "[\(context)] sendButton should be hittable")
    }

    @MainActor
    private func screenshot(_ name: String, app: XCUIApplication) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @MainActor
    private func navigateBackToSessions(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["Sessions"].firstMatch
        if back.waitForExistence(timeout: 3) { back.tap() }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Tab nav smoke

    /// Tap every iOS tab in sequence, assert each pane renders without crash.
    @MainActor
    func testTabNavSmoke() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions")

        let tabs: [(label: String, landmark: String)] = [
            ("Sessions",  "Sessions"),
            ("Cron",      "Cron Jobs"),
            ("Wiki",      "Wiki"),
            ("Skills",    "Skills"),
            ("Artifacts", "Artifacts"),
            ("Feed",      "Feed"),
            ("Learning",  "Learning"),
        ]

        for (label, landmark) in tabs {
            let tab = app.tabBars.buttons[label].firstMatch
            guard tab.waitForExistence(timeout: 5) else { continue }
            tab.tap()
            screenshot("tab-\(label.lowercased())", app: app)
            let found = app.staticTexts[landmark].firstMatch.waitForExistence(timeout: 6)
                || app.navigationBars[landmark].firstMatch.waitForExistence(timeout: 3)
            XCTAssertTrue(found, "Tab '\(label)' — landmark '\(landmark)' not visible after tap")
        }
    }

    // MARK: - Long-session second turn

    /// Send a prompt, wait for the full response, assert the input bar is
    /// immediately usable for a second turn. Repro for "input stuck after
    /// elongated session".
    @MainActor
    func testInputBarUsableAfterFirstResponse() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions")
        openNewSession(app)

        sendMessage(app, text: "Reply with exactly: TURN_ONE_OK")
        screenshot("01-turn-one-sent", app: app)

        XCTAssertTrue(waitForStreamingToFinish(app, timeout: 60), "First response should complete")
        screenshot("02-turn-one-complete", app: app)

        assertInputBarUsable(app, context: "after-first-response")
        screenshot("03-input-bar-usable", app: app)

        sendMessage(app, text: "Reply with exactly: TURN_TWO_OK")
        XCTAssertTrue(waitForStreamingToFinish(app, timeout: 60), "Second response should complete")
        screenshot("04-turn-two-complete", app: app)
    }

    // MARK: - Session switch while streaming

    /// Start a slow prompt in session A, switch to session B, assert B's input
    /// accepts text and the response appears in B not A.
    @MainActor
    func testInputRouting_SwitchSessionWhileStreaming() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions")

        openNewSession(app)
        sendMessage(app, text: "Count from 1 to 20, one number per line, slowly.")
        _ = app.buttons["stopButton"].firstMatch.waitForExistence(timeout: 8)
        screenshot("01-session-a-streaming", app: app)

        navigateBackToSessions(app)
        openNewSession(app)
        screenshot("02-session-b-opened", app: app)

        assertInputBarUsable(app, context: "session-b-while-a-streams")

        sendMessage(app, text: "Reply with exactly: SESSION_B_OK")
        let pred = NSPredicate(format: "label CONTAINS[c] %@", "SESSION_B_OK")
        let visible = app.staticTexts.containing(pred).element.waitForExistence(timeout: 15)
        screenshot("03-session-b-response", app: app)
        XCTAssertTrue(visible, "Session B response should appear in session B")
    }

    // MARK: - Concurrent sessions

    /// Two sessions run simultaneously; both finish and both input bars re-enable.
    @MainActor
    func testConcurrentSessions_BothInputBarsReEnable() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions")

        openNewSession(app)
        sendMessage(app, text: "Reply with exactly: CONCURRENT_A_OK")
        screenshot("01-session-a-sent", app: app)
        navigateBackToSessions(app)

        openNewSession(app)
        sendMessage(app, text: "Reply with exactly: CONCURRENT_B_OK")
        screenshot("02-session-b-sent", app: app)

        XCTAssertTrue(waitForStreamingToFinish(app, timeout: 60), "Session B should finish")
        screenshot("03-session-b-done", app: app)
        assertInputBarUsable(app, context: "session-b-after-completion")

        navigateBackToSessions(app)
        app.cells.element(boundBy: 0).tap()
        XCTAssertTrue(waitForStreamingToFinish(app, timeout: 60), "Session A should finish")
        screenshot("04-session-a-done", app: app)
        assertInputBarUsable(app, context: "session-a-after-both-complete")
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
#endif
