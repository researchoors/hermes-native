#if os(macOS)
import XCTest

// macOS smoke tests: sidebar nav, session lifecycle, input bar correctness,
// wiki canvas interaction.
// Runs against a live gateway — XCTSkip when HERMES_NATIVE_GATEWAY_URL is absent.
final class HermesNativeMacOSSmokeTests: XCTestCase {

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
    private func navigateToSessions(_ app: XCUIApplication) {
        let btn = app.buttons["Sessions"].firstMatch
        if btn.waitForExistence(timeout: 3) { btn.tap() }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Tap a sidebar button, assert a landmark appears, dismiss with Escape.
    /// Skips gracefully when the button is absent (capability-gated pane).
    @MainActor
    private func exerciseSidebarPane(
        app: XCUIApplication,
        buttonLabel: String,
        landmark: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let button = app.buttons[buttonLabel].firstMatch
        guard button.waitForExistence(timeout: 5) else { return }
        button.tap()
        screenshot("pane-\(buttonLabel.lowercased().replacingOccurrences(of: " ", with: "-"))", app: app)
        let found = app.staticTexts[landmark].firstMatch.waitForExistence(timeout: 6)
        XCTAssertTrue(found, "[\(buttonLabel)] landmark '\(landmark)' not found", file: file, line: line)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.4)
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 1) { done.tap() }
    }

    // MARK: - Sidebar nav smoke

    /// Tap every sidebar button in sequence, assert each pane opens without
    /// crash or hang.
    @MainActor
    func testSidebarNavSmoke() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions after connect")

        let panes: [(button: String, landmark: String)] = [
            ("Settings",      "Settings"),
            ("Sessions",      "Sessions"),
            ("Cron Dashboard","Cron Jobs"),
            ("Activity",      "Activity"),
            ("Skills",        "Skills"),
            ("Feed",          "Feed"),
            ("Learning",      "Learning"),
            ("Wiki Graph",    "Wiki"),
            ("Artifacts",     "Artifacts"),
        ]

        for (button, landmark) in panes {
            exerciseSidebarPane(app: app, buttonLabel: button, landmark: landmark)
        }
        screenshot("sidebar-nav-smoke-complete", app: app)
    }

    // MARK: - Long-session second turn

    /// Send a prompt, wait for full response, assert input bar is immediately
    /// usable for a second turn. Repro for "input stuck after elongated session".
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

        navigateToSessions(app)
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
        navigateToSessions(app)

        openNewSession(app)
        sendMessage(app, text: "Reply with exactly: CONCURRENT_B_OK")
        screenshot("02-session-b-sent", app: app)

        XCTAssertTrue(waitForStreamingToFinish(app, timeout: 60), "Session B should finish")
        screenshot("03-session-b-done", app: app)
        assertInputBarUsable(app, context: "session-b-after-completion")

        navigateToSessions(app)
        app.cells.element(boundBy: 0).tap()
        XCTAssertTrue(waitForStreamingToFinish(app, timeout: 60), "Session A should finish")
        screenshot("04-session-a-done", app: app)
        assertInputBarUsable(app, context: "session-a-after-both-complete")
    }

    // MARK: - Wiki canvas

    /// Open the wiki graph, let it settle, tap around the canvas, toggle the
    /// file tree sidebar — assert no crash throughout.
    @MainActor
    func testWikiCanvasInteraction() throws {
        continueAfterFailure = false
        let app = try launchApp()
        XCTAssertTrue(connectAndReachSessions(app), "Should reach Sessions")

        let wikiButton = app.buttons["Wiki Graph"].firstMatch
        guard wikiButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("Wiki Graph button not present — capability not enabled")
        }
        wikiButton.tap()
        screenshot("wiki-01-opened", app: app)

        Thread.sleep(forTimeInterval: 3)
        screenshot("wiki-02-settled", app: app)

        let canvas = app.otherElements.firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.3)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
        Thread.sleep(forTimeInterval: 0.3)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).tap()
        screenshot("wiki-03-tapped", app: app)

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5),
            "App should still be running after wiki canvas interaction"
        )

        let fileTreeToggle = app.buttons["Toggle Sidebar"].firstMatch
        if fileTreeToggle.waitForExistence(timeout: 3) {
            fileTreeToggle.tap()
            Thread.sleep(forTimeInterval: 0.5)
            screenshot("wiki-04-file-tree-open", app: app)
            fileTreeToggle.tap()
        }
        screenshot("wiki-05-done", app: app)
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
